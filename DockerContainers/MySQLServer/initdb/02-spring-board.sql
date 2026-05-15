-- ── Spring Board 스키마 ───────────────────────────────────
-- SpringServer domain 모델(User, Post) 기반
USE spring_board;

CREATE TABLE users (
    id         BIGINT AUTO_INCREMENT PRIMARY KEY,
    username   VARCHAR(50)  NOT NULL UNIQUE,
    password   VARCHAR(255) NOT NULL,          -- 평문 저장 (A02 취약)
    email      VARCHAR(100),
    department VARCHAR(50),
    role       VARCHAR(10)  NOT NULL DEFAULT 'USER'
);

-- UserRepository.seed() 데이터와 동일
INSERT INTO users (username, password, email, department, role) VALUES
    ('admin', 'admin123', 'admin@reznok.local', 'IT보안팀', 'ADMIN'),
    ('alice', '1234',     'alice@reznok.local', '개발1팀',  'USER'),
    ('bob',   'qwerty',   'bob@reznok.local',   '개발2팀',  'USER'),
    ('carol', 'password', 'carol@reznok.local', '기획팀',  'USER');

CREATE TABLE posts (
    id         BIGINT AUTO_INCREMENT PRIMARY KEY,
    title      VARCHAR(200) NOT NULL,
    content    TEXT,
    author     VARCHAR(50),
    author_id  BIGINT,
    category   VARCHAR(50),
    views      INT          NOT NULL DEFAULT 0,
    created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- PostRepository.seed() 데이터와 동일
INSERT INTO posts (title, content, author, author_id, category, created_at) VALUES
    ('[공지] 사내 게시판 오픈 안내',
     '안녕하세요, IT보안팀입니다. 사내 커뮤니케이션을 위해 게시판을 새로 오픈했습니다. 자유롭게 활용해주세요.',
     'admin', 1, '공지', NOW() - INTERVAL 5 DAY),
    ('Spring Boot 2.6.3 업그레이드 일정 공유',
     '다음 주 화요일 오전 2시에 정기 점검과 함께 Spring Boot 2.6.3으로 업그레이드 예정입니다.',
     'admin', 1, '공지', NOW() - INTERVAL 3 DAY),
    ('점심 같이 드실 분 구합니다',
     '오늘 12시 30분 1층 로비에서 모입니다. 댓글 남겨주세요!',
     'alice', 2, '자유', NOW() - INTERVAL 1 DAY),
    ('신규 기획 PT 자료 공유',
     '어제 회의 때 발표한 자료입니다. 피드백 환영합니다.',
     'carol', 4, '업무', NOW() - INTERVAL 6 HOUR),
    ('회의실 예약 시스템 버그 리포트',
     '예약 변경이 가끔 반영되지 않습니다. 재현 케이스 공유드립니다.',
     'bob',   3, '업무', NOW() - INTERVAL 2 HOUR);
