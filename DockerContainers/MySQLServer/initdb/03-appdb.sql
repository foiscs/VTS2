-- ── WAS appdb 스키마 ──────────────────────────────────────
-- WAS(app.py) 가 사용하는 취약 테이블
-- 취약 설계: 평문 패스워드, SQLi 가능한 raw query 대상
USE appdb;

CREATE TABLE IF NOT EXISTS users (
    id       INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(50)  NOT NULL UNIQUE,
    email    VARCHAR(100),
    password VARCHAR(100) NOT NULL               -- 평문 저장 (A02 취약)
);

INSERT INTO users (username, email, password) VALUES
    ('admin', 'admin@corp.internal', 'admin123'),
    ('alice', 'alice@corp.internal', 'alice2024'),
    ('bob',   'bob@corp.internal',   'qwerty'),
    ('carol', 'carol@corp.internal', 'P@ssw0rd');

CREATE TABLE IF NOT EXISTS posts (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    title      VARCHAR(200) NOT NULL,
    author     VARCHAR(50),
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO posts (title, author, created_at) VALUES
    ('내부 서버 점검 공지',    'admin', NOW() - INTERVAL 7 DAY),
    ('WAS 배포 완료 안내',     'admin', NOW() - INTERVAL 3 DAY),
    ('DB 마이그레이션 결과',   'alice', NOW() - INTERVAL 1 DAY),
    ('보안 패치 일정 공유',    'carol', NOW() - INTERVAL 6 HOUR);
