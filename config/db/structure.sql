CREATE TABLE `schema_migrations`(`filename` varchar(255) NOT NULL PRIMARY KEY);
CREATE TABLE `projects`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `slug` varchar(255) NOT NULL UNIQUE,
  `path` varchar(255) NOT NULL,
  `remote` varchar(255),
  `branch` varchar(255),
  `own` boolean NOT NULL,
  `last_commit_at` integer,
  `commits_window` integer NOT NULL,
  `mine_window` integer NOT NULL,
  `dirty` integer NOT NULL,
  `unpushed` integer,
  `scanned_at` integer NOT NULL,
  `present` boolean DEFAULT(1) NOT NULL,
  `icon_path` varchar(255),
  `icon_mtime` integer,
  `pr_remote` varchar(255),
  "local_mode" varchar(255),
  "local_repo" varchar(255),
  `public_repo` varchar(255),
  `public_head` varchar(255),
  "local_error" text,
  `branches` text,
  `default_ref` varchar(255),
  `git_error` text,
  `dirty_paths` text
);
CREATE TABLE `commits`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `project_slug` varchar(255) NOT NULL,
  `sha` varchar(255) NOT NULL,
  `author` varchar(255) NOT NULL,
  `email` varchar(255) NOT NULL,
  `committed_at` integer NOT NULL,
  `subject` varchar(255) NOT NULL,
  `mine` boolean NOT NULL
);
CREATE UNIQUE INDEX `commits_project_slug_sha_index` ON `commits`(
  `project_slug`,
  `sha`
);
CREATE INDEX `commits_committed_at_index` ON `commits`(`committed_at`);
CREATE TABLE `reports`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `date` varchar(255) NOT NULL,
  `title` varchar(255) NOT NULL,
  `body_md` text NOT NULL,
  `author` varchar(255) NOT NULL,
  `created_at` integer NOT NULL
);
CREATE INDEX `reports_date_index` ON `reports`(`date`);
CREATE TABLE `notes`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `project_slug` varchar(255),
  `body` text NOT NULL,
  `author` varchar(255) NOT NULL,
  `created_at` integer NOT NULL
);
CREATE INDEX `notes_project_slug_index` ON `notes`(`project_slug`);
CREATE TABLE `scans`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `started_at` integer NOT NULL,
  `finished_at` integer,
  `repos` integer,
  `error` text
);
CREATE TABLE `daily`(
  `project_slug` varchar(255) NOT NULL,
  `day` varchar(255) NOT NULL,
  `commits` integer NOT NULL,
  `mine` integer NOT NULL,
  PRIMARY KEY(`project_slug`, `day`)
);
CREATE INDEX `daily_day_index` ON `daily`(`day`);
CREATE TABLE `cards`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `project_slug` varchar(255) NOT NULL,
  `column` varchar(255) NOT NULL,
  `position` integer NOT NULL,
  `title` varchar(255) NOT NULL,
  `notes` text DEFAULT('') NOT NULL,
  `labels` text DEFAULT('[]') NOT NULL, `assignee` varchar(255),
  `priority` varchar(255),
  `created_by` varchar(255) NOT NULL,
  `created_at` integer NOT NULL,
  `updated_at` integer NOT NULL,
  `archived_at` integer,
  `due_at` integer,
  `due_done` integer DEFAULT(0) NOT NULL,
  `cover` varchar(255),
  `owner_session` varchar(255),
  `owner_socket` varchar(255),
  `owner_missing_since` integer,
  `approved_at` integer,
  `approved_by` varchar(255),
  `qa_notes` text,
  `pr_url` varchar(255),
  `ci_url` varchar(255),
  `ui_change` boolean,
  `handoff_at` integer,
  `handoff_by` varchar(255),
  `question` text,
  `question_options` text,
  `asked_at` integer,
  `asked_by` varchar(255),
  `dialog_id` integer,
  `parent_id` integer,
  `metadata` text,
  `blocked_at` integer,
  `blocked_author` varchar(255),
  `blocked_reason` text,
  `blocked_url` text,
  `flag_reminded_at` integer,
  `review_rounds` text,
  `gate_head` varchar(255),
  `gate_state` text
);
CREATE INDEX `cards_project_slug_column_position_index` ON `cards`(
  `project_slug`,
  `column`,
  `position`
);
CREATE TABLE `card_activity`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `card_id` integer NOT NULL REFERENCES `cards` ON DELETE CASCADE,
  `kind` varchar(255) NOT NULL,
  `body` text NOT NULL,
  `author` varchar(255) NOT NULL,
  `created_at` integer NOT NULL,
  `edited_at` integer,
  `by_operator` boolean,
  `undelivered` boolean
);
CREATE INDEX `card_activity_card_id_index` ON `card_activity`(`card_id`);
CREATE TABLE `board_labels`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `project_slug` varchar(255) NOT NULL,
  `name` varchar(255) NOT NULL,
  `color` varchar(255) NOT NULL,
  `created_at` integer NOT NULL
);
CREATE UNIQUE INDEX `board_labels_project_slug_name_index` ON `board_labels`(
  `project_slug`,
  `name`
);
CREATE TABLE `checklists`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `card_id` integer NOT NULL REFERENCES `cards` ON DELETE CASCADE,
  `title` varchar(255) NOT NULL,
  `position` integer NOT NULL,
  `created_at` integer NOT NULL
);
CREATE INDEX `checklists_card_id_index` ON `checklists`(`card_id`);
CREATE TABLE `checklist_items`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `checklist_id` integer NOT NULL REFERENCES `checklists` ON DELETE CASCADE,
  `body` text NOT NULL,
  `done` integer DEFAULT(0) NOT NULL,
  `position` integer NOT NULL,
  `done_by` varchar(255),
  `done_at` integer,
  `created_at` integer NOT NULL
);
CREATE INDEX `checklist_items_checklist_id_index` ON `checklist_items`(
  `checklist_id`
);
CREATE TABLE `card_pings`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `card_id` integer NOT NULL,
  `session` varchar(255) NOT NULL,
  `socket` varchar(255) NOT NULL,
  `text` text NOT NULL,
  `reason` varchar(255) NOT NULL,
  `status` varchar(255) NOT NULL,
  `attempts` integer DEFAULT(0) NOT NULL,
  `error` text,
  `created_at` integer NOT NULL,
  `done_at` integer
);
CREATE INDEX `card_pings_status_created_at_index` ON `card_pings`(
  `status`,
  `created_at`
);
CREATE TABLE `card_attachments`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `card_id` integer NOT NULL,
  `activity_id` integer,
  `filename` varchar(255) NOT NULL,
  `content_type` varchar(255) NOT NULL,
  `size` integer NOT NULL,
  `sha256` varchar(255) NOT NULL,
  `stored_path` varchar(255) NOT NULL,
  `uploaded_by` varchar(255) NOT NULL,
  `created_at` integer NOT NULL,
  `deleted_at` integer,
  `deleted_by` varchar(255)
);
CREATE INDEX `card_attachments_card_id_deleted_at_index` ON `card_attachments`(
  `card_id`,
  `deleted_at`
);
CREATE INDEX `card_attachments_activity_id_index` ON `card_attachments`(
  `activity_id`
);
CREATE TABLE `gh_users`(
  `login` varchar(255) NOT NULL PRIMARY KEY,
  `gh_id` integer,
  `name` varchar(255),
  `bio` text,
  `avatar_url` varchar(255),
  `html_url` varchar(255),
  `followers` integer,
  `public_repos` integer,
  `profile_at` integer,
  `following_synced_at` integer
);
CREATE TABLE `gh_follows`(
  `follower` varchar(255) NOT NULL,
  `followee` varchar(255) NOT NULL,
  `first_seen_at` integer NOT NULL,
  `last_seen_at` integer NOT NULL,
  `baseline` boolean NOT NULL,
  `gone_at` integer,
  PRIMARY KEY(`follower`, `followee`)
);
CREATE INDEX `gh_follows_followee_index` ON `gh_follows`(`followee`);
CREATE INDEX `gh_follows_first_seen_at_index` ON `gh_follows`(`first_seen_at`);
CREATE TABLE `gh_repos`(
  `full_name` varchar(255) NOT NULL PRIMARY KEY,
  `gh_id` integer,
  `description` text,
  `language` varchar(255),
  `stargazers_count` integer,
  `html_url` varchar(255) NOT NULL,
  `owner_avatar` varchar(255),
  `topics` text,
  `pushed_at` integer,
  `fetched_at` integer NOT NULL
);
CREATE TABLE `gh_stars`(
  `login` varchar(255) NOT NULL,
  `repo` varchar(255) NOT NULL,
  `starred_at` integer NOT NULL,
  `first_seen_at` integer NOT NULL,
  PRIMARY KEY(`login`, `repo`)
);
CREATE INDEX `gh_stars_starred_at_index` ON `gh_stars`(`starred_at`);
CREATE TABLE `gh_pages`(
  `url` varchar(255) NOT NULL PRIMARY KEY,
  `etag` varchar(255) NOT NULL,
  `items` text,
  `at` integer NOT NULL
);
CREATE TABLE `gh_runs`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `login` varchar(255) NOT NULL,
  `started_at` integer NOT NULL,
  `finished_at` integer,
  `ok` boolean,
  `error` text,
  `baseline` boolean DEFAULT(0) NOT NULL,
  `calls` integer DEFAULT(0) NOT NULL,
  `not_modified` integer DEFAULT(0) NOT NULL,
  `rate_limit` integer,
  `rate_remaining` integer,
  `rate_reset` integer,
  `followees` integer,
  `stars_added` integer,
  `follows_added` integer,
  `feed_ok` boolean,
  `feed_error` text,
  `feed_added` integer,
  `feed_calls` integer,
  `feed_not_modified` integer,
  `feed_gap` boolean
);
CREATE TABLE `session_dialogs`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `session` varchar(255) NOT NULL,
  `socket` varchar(255) NOT NULL,
  `hash` varchar(255) NOT NULL,
  `card_id` integer NOT NULL,
  `dialog` text NOT NULL,
  `posted_at` integer NOT NULL,
  `answered_at` integer,
  `answered_by` varchar(255),
  `answer` varchar(255)
);
CREATE INDEX `session_dialogs_session_hash_index` ON `session_dialogs`(
  `session`,
  `hash`
);
CREATE TABLE `gh_events`(
  `login` varchar(255) NOT NULL,
  `id` varchar(255) NOT NULL,
  `type` varchar(255) NOT NULL,
  `action` varchar(255),
  `actor` varchar(255) NOT NULL,
  `actor_avatar` varchar(255),
  `repo` varchar(255) NOT NULL,
  `public` boolean,
  `created_at` integer NOT NULL,
  `first_seen_at` integer NOT NULL,
  `digest` text NOT NULL,
  PRIMARY KEY(`login`, `id`)
);
CREATE INDEX `gh_events_login_created_at_index` ON `gh_events`(
  `login`,
  `created_at`
);
CREATE TABLE `agent_sessions`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `session` varchar(255) NOT NULL,
  `socket` varchar(255) NOT NULL,
  `project_slug` varchar(255) NOT NULL,
  `type_key` varchar(255) NOT NULL,
  `launcher_key` varchar(255) NOT NULL,
  `agent_name` varchar(255) NOT NULL,
  `launched_by` varchar(255) NOT NULL,
  `launched_at` integer NOT NULL,
  `last_seen_at` integer,
  `ended_at` integer,
  `end_reason` text
);
CREATE INDEX `agent_sessions_session_ended_at_index` ON `agent_sessions`(
  `session`,
  `ended_at`
);
CREATE INDEX `agent_sessions_project_slug_ended_at_index` ON `agent_sessions`(
  `project_slug`,
  `ended_at`
);
CREATE TABLE `ci_watches`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `card_id` integer NOT NULL,
  `kind` varchar(255) NOT NULL,
  `ref` integer NOT NULL,
  `pr` integer,
  `state` varchar(255),
  `pinged_at` integer,
  `commented_at` integer,
  `created_at` integer NOT NULL,
  UNIQUE(`card_id`, `kind`, `ref`)
);
CREATE TABLE `gh_pr_checks`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `repo` varchar(255) NOT NULL,
  `ref` varchar(255) NOT NULL,
  `requested_at` integer NOT NULL,
  `checked_at` integer,
  `number` integer,
  `state` varchar(255),
  `finished_at` integer,
  `error` text,
  `detail` text,
  `head` varchar(255),
  UNIQUE(`repo`, `ref`)
);
CREATE TABLE `boards`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `project_slug` varchar(255) NOT NULL UNIQUE,
  `updated_by` varchar(255) NOT NULL,
  `updated_at` integer NOT NULL,
  `created_at` integer NOT NULL
);
CREATE TABLE `board_columns`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `project_slug` varchar(255) NOT NULL,
  `key` varchar(255) NOT NULL,
  `label` varchar(255) NOT NULL,
  `type` varchar(255) NOT NULL,
  `position` integer NOT NULL,
  `hide_after_hours` integer,
  UNIQUE(`project_slug`, `key`)
);
CREATE TABLE `board_transitions`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `project_slug` varchar(255) NOT NULL,
  `position` integer NOT NULL,
  `name` varchar(255) NOT NULL,
  `from_keys` text NOT NULL,
  `to_key` varchar(255) NOT NULL,
  `by` varchar(255) NOT NULL
);
CREATE INDEX `board_transitions_project_slug_index` ON `board_transitions`(
  `project_slug`
);
CREATE TABLE `gh_merged_prs`(
  `login` varchar(255) NOT NULL,
  `repo` varchar(255) NOT NULL,
  `number` integer NOT NULL,
  `title` text NOT NULL,
  `url` varchar(255) NOT NULL,
  `merged_at` integer NOT NULL,
  `first_seen_at` integer NOT NULL,
  PRIMARY KEY(`login`, `repo`, `number`)
);
CREATE INDEX `gh_merged_prs_login_merged_at_index` ON `gh_merged_prs`(
  `login`,
  `merged_at`
);
CREATE TABLE `gh_pr_runs`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `login` varchar(255) NOT NULL,
  `since` varchar(255) NOT NULL,
  `started_at` integer NOT NULL,
  `finished_at` integer,
  `ok` boolean,
  `error` text,
  `found` integer,
  `added` integer,
  `calls` integer
);
CREATE INDEX `gh_pr_runs_login_id_index` ON `gh_pr_runs`(`login`, `id`);
CREATE TABLE `agent_seen`(
  `key` varchar(255) NOT NULL PRIMARY KEY,
  `seen_at` double precision NOT NULL
);
CREATE TABLE `gh_pr_states`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `repo` varchar(255) NOT NULL,
  `ref` varchar(255) NOT NULL,
  `requested_at` integer NOT NULL,
  `checked_at` integer,
  `number` integer,
  `url` varchar(255),
  `state` varchar(255),
  `error` text,
  UNIQUE(`repo`, `ref`)
);
CREATE TABLE `agent_settings`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `doc` text NOT NULL,
  `author` varchar(255) NOT NULL,
  `created_at` integer NOT NULL
);
CREATE TABLE `daily_report_settings`(
  `id` integer NOT NULL PRIMARY KEY AUTOINCREMENT,
  `doc` text NOT NULL,
  `author` varchar(255) NOT NULL,
  `created_at` integer NOT NULL
);
INSERT INTO schema_migrations (filename) VALUES
('20261101000000_create_core.rb'),
('20261101230000_create_daily.rb'),
('20261102000000_create_kanban.rb'),
('20261102120000_add_project_icons.rb'),
('20261103000000_kanban_trello.rb'),
('20261104000000_kanban_owner_sessions.rb'),
('20261105000000_card_attachments.rb'),
('20261106000000_card_approval.rb'),
('20261107000000_card_handoff.rb'),
('20261108000000_github_network.rb'),
('20261109000000_card_question.rb'),
('20261110000000_session_dialogs.rb'),
('20261111000000_github_feed.rb'),
('20261112000000_agents_kanban_schema.rb'),
('20261113000000_agent_sessions.rb'),
('20261114000000_agents_kanban_ci_watches.rb'),
('20261114000001_gh_pr_checks.rb'),
('20261115000000_agents_kanban_workflows.rb'),
('20261116000000_agents_kanban_boards.rb'),
('20261117000000_projects_pr_remote.rb'),
('20261118000000_gh_merged_prs.rb'),
('20261119000000_agent_seen.rb'),
('20261120000000_agents_kanban_hide_after_hours.rb'),
('20261121000000_pr_flags.rb'),
('20261122000000_agents_kanban_workflow_v3.rb'),
('20261123000000_gh_pr_checks_detail.rb'),
('20261124000000_agents_kanban_board_positions.rb'),
('20261125000000_agents_kanban_gate_head.rb'),
('20261127000000_projects_git_read.rb'),
('20261130000000_local_naming.rb'),
('20261201000000_projects_dirty_paths.rb'),
('20261202000000_agent_settings.rb'),
('20261203000000_cards_assigned_prs.rb'),
('20261204000000_daily_report_settings.rb');
