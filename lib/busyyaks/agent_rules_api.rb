# frozen_string_literal: true

require "digest"
require_relative "kanban"
require_relative "markdown"
require_relative "agent_rule_files"
require_relative "skills"
require_relative "git_read"
require_relative "launcher_client"
require_relative "writer_client"

module Busyyaks
  # Settings → Agent rules: busyyaks's OWN skills layers — what every session busyyaks launches gets, per agent type,
  # in the order a launch stages it — read from bin/launcher (it reads the HOST checkout at every launch; the web
  # image's copy can be older: op skills_layers = Skills.global_view, the launch's own selection, never a second
  # definition of the order) and written through the writer service (SkillFiles). [status, body]:
  #   show  → 200 {checkout: {host, mount, error}, limits, agent_types: [{key, label, under, takes, standalone,
  #           launchers, start, on_demand, start_bytes, budget}], files: [{path, source, kind, load, skill, description,
  #           type, exists, bytes, sha, eol, body, html, git, error, replaced_by (the source whose file stands in for
  #           it: the override rule, Skills.select — it is in no launch) }], git_error} · 503 launcher down / too old
  #           ("restart it") · 422 its refusal (an invalid layer: every launch is refused too)
  #   save(body) → the writer's answer: 200 the same as show, re-read · 409 changed on disk · 422 refused
  # A file's body has LF line ends (a textarea's); eol says what the file has (a save writes CRLF back).
  module AgentRulesAPI
    module_function

    def show(db: Kanban.db, launcher: LauncherClient, root: GitRead.mount)
      status, view = view(db: db, launcher: launcher)
      return [status, view] unless status == 200

      git, git_error = git(view, root)
      view[:files].each { |f| f[:git] = git[f[:path]] }
      [200, view.merge(git_error: git_error)]
    end

    def save(body, by:, db: Kanban.db, launcher: LauncherClient, root: GitRead.mount)
      return [422, { error: "body must be an object {files}" }] unless body.is_a?(Hash) && body.key?("files")

      # the writer finds the checkout itself (never a path from here) and checks everything again
      status, out = WriterClient.skills_save(body["files"], by: by)
      status == 200 ? show(db: db, launcher: launcher, root: root) : [status, out]
    end

    # the launcher's answer as the page shows it (no git) → [status, body]. The project page's Settings tab shows the
    # same view as the layers a project's file adds to.
    def view(db: Kanban.db, launcher: LauncherClient)
      cfg = Kanban.config(db)
      res = launcher.skills_layers(settings: Kanban.revision_of(cfg))
      return refusal(res) unless res["ok"]

      [200, shape(cfg, res)]
    rescue LauncherClient::Unavailable => e
      [503, { error: e.message }]
    end

    # an answer without a status is not this op's — an older launcher's "unknown op": said, never guessed
    def refusal(res)
      return [Integer(res["status"]), { error: res["error"].to_s }] if res["status"]

      [503, { error: "launcher protocol error (#{res['error']}): restart it (deploy/install-launcher.sh)" }]
    end

    def shape(cfg, res)
      types = res.fetch("types")
      files = res.fetch("files").map { |f| file(f) } +
              res.fetch("creatable").map { |p| missing(p, res.dig("limits", "local_dir")) }
      { checkout: res.fetch("checkout").transform_keys(&:to_sym), limits: res.fetch("limits").transform_keys(&:to_sym),
        agent_types: cfg.agent_types.map { |t| agent_type(t, types.fetch(t.key)) }, files: files, }
    end

    def agent_type(type, layers)
      { key: type.key, label: type.label, under: type.under, takes: type.takes, standalone: type.standalone ? true : false,
        launchers: type.launchers, start: layers.fetch("start"), on_demand: layers.fetch("on_demand"),
        start_bytes: layers.fetch("start_bytes"), budget: layers.fetch("budget"), }
    end

    def file(f)
      text = f["text"]
      eol = text ? AgentRuleFiles.eol_of(text) : AgentRuleFiles::LF
      body = text && eol == AgentRuleFiles::CRLF ? text.gsub("\r\n", "\n") : text
      bytes = text&.b
      { path: f.fetch("path"), source: f.fetch("source"), kind: f.fetch("kind"), load: f.fetch("load"),
        skill: f["skill"], description: f["description"], dispatch: f["dispatch"],
        type: type_of(f.fetch("path"), f.fetch("kind")),
        exists: true, bytes: f.fetch("bytes"), sha: bytes && AgentRuleFiles.sha(bytes),
        blob: bytes && Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0#{bytes}"), eol: eol,
        body: body, html: body ? Markdown.render(strip_front(body)) : nil, error: f["error"],
        replaced_by: f["replaced_by"], }
    end

    # an agents/<type>.md no layer has yet: an empty editor (Save makes it)
    def missing(path, local_dir)
      { path: path, source: local_dir && path.start_with?("#{local_dir}/") ? Skills::DEPLOYMENT : Skills::BUSYYAKS,
        kind: "agent", load: "start", skill: nil, description: nil, dispatch: nil, type: type_of(path, "agent"),
      exists: false,
        bytes: 0, sha: nil, blob: nil, eol: AgentRuleFiles::LF, body: "", html: "", error: nil, replaced_by: nil, }
    end

    def type_of(path, kind) = kind == "agent" ? File.basename(path, ".md") : nil

    # a SKILL.md's frontmatter (name + description, shown beside it) is not rendered as text
    def strip_front(text) = text.sub(/\A---\r?\n.*?^---\r?\n/m, "")

    # {path => committed | modified | added | ignored | untracked | deleted}, or [{}, why git could not be read]
    def git(view, root)
      mount = view.dig(:checkout, :mount) or return [{}, view.dig(:checkout, :error)]

      files = view[:files]
      r = GitRead.call("tracked", path: mount, root: root, files: files.map { |f| f[:path] })
      states = files.to_h do |f|
        file = f[:exists] && f[:blob] ? { blob: f[:blob] } : nil
        [f[:path], AgentRuleFiles.git_state(file, r.fetch("files").fetch(f[:path]))]
      end
      files.each { |f| f.delete(:blob) }
      [states.compact, nil]
    rescue GitRead::Failed => e
      view[:files].each { |f| f.delete(:blob) }
      [{}, e.message]
    end
  end
end
