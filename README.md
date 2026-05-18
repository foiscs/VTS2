# VTS2 — 네트워크 보안 실습 랩

컨테이너 기반 네트워크 보안 실습 환경입니다.  
FRR 라우터, Suricata 인라인 IPS, DMZ/Intranet/DB 존 분리, 취약 웹앱(DVWA, Spring4Shell)으로 구성됩니다.

---

## 토폴로지

```
외부(10.0.1.100/veth-ext)
        │
   Router / FRR (10.0.1.1)
        │
  Suricata IPS (AF_PACKET inline)
        │
     sw-dmz (브리지)
        ├── DVWA        10.0.10.10   포트 80
        ├── Spring      10.0.10.20   포트 8080
        └── fw-int eth1 10.0.10.254
                │
          sw-intranet (브리지)
                └── WAS / ProxySQL  10.0.20.10   포트 3306
                │
             sw-db (브리지)
                └── MySQL           10.0.30.10   포트 3306
```

---

## 사전 요구사항

### Docker
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

### ContainerLab
```bash
bash -c "$(curl -sL https://get.containerlab.dev)"
```

### 저장소 클론
```bash
git clone https://github.com/foiscs/VTS2
cd VTS2
```

---

## 배포

### 1단계 — 이미지 빌드

```bash
cd DockerContainers/SpringServer
docker build -t vts-spring:latest .
cd DockerContainers/DVWA
docker build -t vulnerables/web-dvwa:local .
cd ../..
```

> 최초 1회만 빌드하면 됩니다. 소스 변경 시 재빌드 필요.

### 2단계 — 토폴로지 배포

```bash
sudo ./deploy-router-only.sh
```

수행 내용:
- sw-dmz / sw-intranet / sw-db 브리지 생성
- ContainerLab 배포 (router, dvwa, spring, fw-int, was, mysqlserver1)
- veth-ext IP 설정 (10.0.1.100/24)
- 각 컨테이너 네트워크 설정 (nsenter)
- fw-int iptables 방화벽 정책 적용

### 3단계 — Suricata IPS 시작

```bash
sudo ./start-suricata.sh
```

수행 내용:
- veth-dmz 생성 및 sw-dmz 연결
- Suricata 컨테이너 시작 (AF_PACKET inline 모드)

### 4단계 — DVWA DB 초기화

브라우저에서 `http://10.0.10.10/setup.php` 접속 →  
**Create / Reset Database** 클릭 → `Setup successful` 확인

로그인: `admin` / `password`  
보안 레벨: DVWA Security → **high** 설정

### 5단계 — 외부 접근 포트포워딩 (선택)

외부 PC에서 접근이 필요한 경우:

```bash
sudo ./setup-port-forward.sh
```

완료 후 출력된 host IP로 접속:
- DVWA  → `http://<host-ip>:8001/`
- Spring → `http://<host-ip>:8002/main/login`

> iptables 규칙을 재부팅 후에도 유지하려면:
> ```bash
> sudo apt install iptables-persistent -y
> sudo iptables-save > /etc/iptables/rules.v4
> ```

---

## 접속 정보

| 서비스 | 내부 주소 | 외부 포트 | 계정 |
|--------|-----------|-----------|------|
| DVWA | http://10.0.10.10/ | 8001 | admin / password |
| Spring | http://10.0.10.20:8080/main/login | 8002 | 회원가입 후 사용 |
| ProxySQL Admin | 10.0.20.10:6032 | — | admin / admin |
| MySQL | 10.0.30.10:3306 | — | dvwa / dvwapass |

---

## 보안 정책

### Suricata 룰 (`configs/suricata/rules/local.rules`)

| SID | 분류 | 액션 |
|-----|------|------|
| 1000001 | SQLi UNION SELECT | alert |
| 1000002–1000004 | SQLi (OR 1=1, 싱글쿼트) | alert |
| 1001001–1001002 | XSS | alert |
| 1002001–1002002 | Spring4Shell (CVE-2022-22965) | alert |
| 1003001 | PHP iconv RCE (CVE-2024-2961) | alert |
| 1004001–1004002 | Path Traversal | alert |
| 1005001 | DMZ→DB 직접 접근 | alert |
| 1006001 | 포트 스캔 | alert |
| 1007001 | DMZ→External 비HTTP 아웃바운드 | alert |
| 1009001–1009002 | 외부→Intranet/DB 직접 접근 | alert |

### fw-int iptables (`DMZ ↔ Intranet 경계`)

FORWARD 기본 정책: **DROP**

| 출발 IP | 목적 IP | 프로토콜 | 포트 | 방향 | 정책 |
|---------|---------|---------|------|------|------|
| 10.0.10.10 (DVWA) | 10.0.20.10 (WAS) | TCP | 3306 | → | ALLOW |
| 10.0.20.10 (WAS) | 10.0.10.10 (DVWA) | TCP | 3306 | ← | ALLOW (ESTABLISHED) |
| 10.0.10.20 (Spring) | 10.0.20.10 (WAS) | TCP | 3306 | → | ALLOW |
| 10.0.20.10 (WAS) | 10.0.10.20 (Spring) | TCP | 3306 | ← | ALLOW (ESTABLISHED) |
| 10.0.20.10 (WAS) | 10.0.30.10 (MySQL) | TCP | 3306 | → | ALLOW |
| 10.0.30.10 (MySQL) | 10.0.20.10 (WAS) | TCP | 3306 | ← | ALLOW (ESTABLISHED) |
| ANY | ANY | ANY | ANY | — | DROP |

---

## 탐지 로그 확인

```bash
# 실시간 탐지 로그
tail -f /var/log/suricata/fast.log

# SQLi 테스트
curl "http://10.0.10.10/vulnerabilities/sqli/?id=1+UNION+SELECT+1,2--&Submit=Submit"

# Spring4Shell 테스트
curl "http://10.0.10.20:8080/main/post/write?class.module.classLoader.resources.context.parent.pipeline.first.pattern=x"

# 룰 리로드
docker exec suricata-ips suricatasc -c reload-rules
```

---

## 정리

```bash
# Suricata 중지
docker rm -f suricata-ips

# 포트포워딩 제거
sudo ./setup-port-forward.sh --flush

# 전체 토폴로지 제거
sudo ./deploy-router-only.sh --destroy
```

---

## 디렉토리 구조

```
VTS2/
├── router-only.yml              # ContainerLab 토폴로지
├── deploy-router-only.sh        # 배포 스크립트
├── start-suricata.sh            # Suricata 시작 스크립트
├── setup-port-forward.sh        # 외부 접근 포트포워딩
├── configs/
│   ├── frr/
│   │   ├── router/              # FRR 라우터 설정
│   │   └── fw-int/              # FRR 방화벽 설정
│   ├── suricata/
│   │   ├── suricata.yaml        # Suricata 설정
│   │   └── rules/local.rules    # 탐지/차단 룰
│   └── proxysql/
│       └── proxysql.cnf         # ProxySQL 설정
└── DockerContainers/
    ├── DVWA/
    │   └── config.inc.php       # DVWA DB 연결 설정
    ├── SpringServer/            # Spring4Shell 취약 서버
    └── mysql/
        └── init.sql             # spring DB 초기화
```

## VM 호스트 사양

| 항목 | 사양 |
|------|------|
| OS | Ubuntu |
| Memory | 4GB |
| Processors | 2 Core |
| Disk | 30GB |

## 컨테이너 리소스 사용량

| NAME | CPU % | MEM USAGE | MEM % |
|------|-------|-----------|-------|
| router/F/W | 0.05% | 7MB | 0.18% |
| suricata-ips | 0.5% | 14MB | 0.40% |
| dvwa | 0.01% | 18MB | 0.53% |
| spring | 0.3% | 300MB | 8.86% |
| fw-int | 0.05% | 5MB | 0.14% |
| was | 0.3% | 9MB | 0.26% |
| mysqlserver1 | 0.5% | 80MB | 2.39% |
| **TOTAL** | **1.71%** | **433MB** | **12.76%** |

## 이미지 디스크 사용량

| IMAGE | DISK USAGE | CONTENT SIZE |
|-------|------------|--------------|
| frrouting/frr:latest | 230MB | 70.3MB |
| jasonish/suricata:8.0.4-amd64 | 586MB | 141MB |
| mysql:8.0 | 1.1GB | 249MB |
| proxysql/proxysql:latest | 682MB | 176MB |
| vts-spring:latest | 1.16GB | 385MB |
| vulnerables/web-dvwa:local | 935MB | 178MB |
| **TOTAL (6 images)** | **4.69GB** | **1.20GB** |