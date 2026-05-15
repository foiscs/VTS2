-- ── 계정 설정 ─────────────────────────────────────────────
-- root 원격 접근 허용 (취약 설정 — 펜테스트 랩 전용)
ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;

-- DVWA 전용 계정: config.inc.php 설정과 동일
-- MySQL 8: GRANT 전 CREATE USER 필요
CREATE USER IF NOT EXISTS 'dvwa'@'%' IDENTIFIED BY 'p@ssw0rd';
GRANT ALL PRIVILEGES ON dvwa.* TO 'dvwa'@'%';

-- Spring Board 전용 계정
CREATE USER IF NOT EXISTS 'spring'@'%' IDENTIFIED WITH mysql_native_password BY 'spring123';
CREATE DATABASE IF NOT EXISTS spring_board CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON spring_board.* TO 'spring'@'%';

FLUSH PRIVILEGES;
