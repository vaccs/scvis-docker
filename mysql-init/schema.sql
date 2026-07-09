-- SCVis database schema, applied by scvis/entrypoint.sh on every container
-- start.
--
-- This is tracked here in scvis-docker rather than pulled from the cloned
-- scvis-go repo: scvis-go's own scripts/scvis_backup.sql is a data dump of an
-- old schema, missing the `administrator` column that
-- internal/models/users.go actually reads/writes. This file reflects the
-- current, correct schema (base tables + the add_inputfileids_column.sql /
-- add_inputfiles_table.sql / add_issues_table.sql migrations that were
-- applied on top of it), plus the `sessions` table required by
-- alexedwards/scs/mysqlstore.
--
-- Table order matters: users and sessions first (no FK dependencies), then
-- projects (FK -> users), then cfiles/inputfiles (FK -> projects), then
-- issues (FK -> users).

CREATE DATABASE IF NOT EXISTS scvis CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

USE scvis;

CREATE TABLE IF NOT EXISTS users (
    id              INT NOT NULL AUTO_INCREMENT,
    name            VARCHAR(255) NOT NULL,
    email           VARCHAR(255) NOT NULL,
    hashed_password CHAR(60) NOT NULL,
    administrator   TINYINT(1) NOT NULL DEFAULT 0,
    PRIMARY KEY (id),
    UNIQUE KEY users_uc_email (email)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS sessions (
    token  CHAR(43) NOT NULL,
    data   BLOB NOT NULL,
    expiry TIMESTAMP(6) NOT NULL,
    PRIMARY KEY (token),
    KEY sessions_expiry_idx (expiry)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS projects (
    id           INT NOT NULL AUTO_INCREMENT,
    title        VARCHAR(255) NOT NULL,
    userid       INT NOT NULL,
    cfileids     JSON NOT NULL,
    inputfileids JSON NOT NULL,
    analysis     BLOB,
    created_at   TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP,
    parameters   VARCHAR(255) DEFAULT NULL,
    PRIMARY KEY (id),
    KEY fk_projects_userid (userid),
    CONSTRAINT fk_projects_userid FOREIGN KEY (userid) REFERENCES users (id) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS cfiles (
    id        INT NOT NULL AUTO_INCREMENT,
    projectid INT NOT NULL,
    filename  VARCHAR(255) NOT NULL,
    csource   TEXT NOT NULL,
    created   TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY fk_cfiles_projectid (projectid),
    CONSTRAINT fk_cfiles_projectid FOREIGN KEY (projectid) REFERENCES projects (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS inputfiles (
    id        INT NOT NULL AUTO_INCREMENT,
    projectid INT NOT NULL,
    filename  VARCHAR(255) NOT NULL,
    data      TEXT NOT NULL,
    created   TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY fk_inputfiles_projectid (projectid),
    CONSTRAINT fk_inputfiles_projectid FOREIGN KEY (projectid) REFERENCES projects (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS issues (
    id                  INT NOT NULL AUTO_INCREMENT,
    user_id             INT NOT NULL,
    title               VARCHAR(200) NOT NULL,
    description         TEXT NOT NULL,
    issue_type          ENUM('bug', 'feature', 'enhancement', 'documentation', 'question') NOT NULL,
    priority            ENUM('low', 'medium', 'high', 'critical') NOT NULL,
    status              ENUM('pending', 'submitted', 'acknowledged', 'in_progress', 'resolved', 'closed') NOT NULL DEFAULT 'pending',
    github_issue_number INT NULL,
    github_url          VARCHAR(255) NULL,
    created             DATETIME NOT NULL,
    updated             DATETIME NOT NULL,
    PRIMARY KEY (id),
    KEY idx_user_id (user_id),
    KEY idx_status (status),
    KEY idx_created (created),
    KEY idx_github_issue_number (github_issue_number),
    CONSTRAINT fk_issues_user_id FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
