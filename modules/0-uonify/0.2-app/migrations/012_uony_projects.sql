CREATE TABLE uony_projects (
 user_id uuid NOT NULL REFERENCES users(id),
 id uuid NOT NULL,
 name text NOT NULL CHECK(char_length(name) BETWEEN 1 AND 80),
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(user_id,id)
);
CREATE TABLE uony_threads (
 user_id uuid NOT NULL REFERENCES users(id),
 id text NOT NULL,
 project_id uuid,
 title text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(user_id,id),
 FOREIGN KEY(user_id,project_id) REFERENCES uony_projects(user_id,id)
);
INSERT INTO uony_threads(user_id,id,title,created_at)
 SELECT DISTINCT ON (user_id,thread_id) user_id,thread_id,left(prompt,70),created_at
 FROM uony_requests ORDER BY user_id,thread_id,created_at;
