# frozen_string_literal: true

module Busyyaks
  # Projects as a folder tree: slugs split on "/" (acme/x → folder acme, repo x). A folder carries
  # the totals of everything under it; siblings are ordered by most recent commit, folders and repos mixed.
  module Tree
    Folder = Struct.new(:name, :path, :children, keyword_init: true) do
      def folder? = true
      def repos = children.flat_map { |c| c.folder? ? c.repos : [c] }
      def last_commit_at = repos.map { |p| p.last_commit_at.to_i }.max.to_i
      def sum(key) = repos.sum { |p| p.send(key).to_i }
      def unpushed_known = repos.map(&:unpushed).compact
    end

    Repo = Struct.new(:project, :name, keyword_init: true) do
      def folder? = false
      def method_missing(key, *) = project.key?(key) ? project[key] : super
      def respond_to_missing?(key, priv = false) = project.key?(key) || super
    end

    module_function

    def build(projects)
      root = Folder.new(name: "", path: "", children: [])
      projects.each do |p|
        *dirs, leaf = p[:slug].split("/")
        node = root
        dirs.each_with_index do |d, i|
          path = dirs[0..i].join("/")
          node = node.children.find { |c| c.folder? && c.path == path } ||
                 Folder.new(name: d, path: path, children: []).tap { |f| node.children << f }
        end
        node.children << Repo.new(project: p, name: leaf)
      end
      sort!(root)
      root.children
    end

    def sort!(folder)
      folder.children.sort_by! { |c| -c.last_commit_at.to_i }
      folder.children.each { |c| sort!(c) if c.folder? }
    end
  end
end
