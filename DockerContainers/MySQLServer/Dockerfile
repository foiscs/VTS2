# MySQL 8.0 — Private 존 DB 서버 (db1: 10.0.20.10/24)
# 펜테스트 랩 전용: 취약한 설정 + 민감 데이터 포함
FROM mysql:8.0

# iproute2: nsenter 기반 네트워크 구성(setup-network.sh)에 필요
RUN microdnf update -y && microdnf install -y iproute && microdnf clean all

# 취약한 MySQL 설정 적용
COPY my.cnf /etc/mysql/conf.d/pentest.cnf

# 초기화 SQL (docker-entrypoint-initdb.d 순서대로 실행)
COPY initdb/ /docker-entrypoint-initdb.d/

# 기본 계정 (DVWA config.inc.php와 일치)
ENV MYSQL_ROOT_PASSWORD=root
ENV MYSQL_DATABASE=dvwa
ENV MYSQL_USER=dvwa
ENV MYSQL_PASSWORD=p@ssw0rd

EXPOSE 3306
