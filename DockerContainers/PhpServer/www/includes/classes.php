<?php
/**
 * includes/classes.php — 애플리케이션 공통 클래스
 *
 * [취약 포인트: PHP Object Injection]
 *  unserialize()에 사용자 입력이 전달될 때,
 *  아래 클래스들의 매직 메서드(__destruct, __wakeup)가
 *  공격자가 원하는 인자로 자동 실행됩니다.
 *
 * 가젯 요약:
 *  ┌─────────────┬──────────────┬────────────────────────────────┐
 *  │ 클래스       │ 매직 메서드  │ 위험 동작                      │
 *  ├─────────────┼──────────────┼────────────────────────────────┤
 *  │ Logger      │ __destruct   │ $log_data → $log_file 쓰기     │
 *  │ CacheLoader │ __wakeup     │ $config_path include()         │
 *  │ FileHelper  │ __toString   │ $filepath file_get_contents()  │
 *  └─────────────┴──────────────┴────────────────────────────────┘
 */

/* ════════════════════════════════════════════════════════════
   Logger — 가젯 1
   공격 시나리오:
     $log_file = '/var/www/html/uploads/shell.php'
     $log_data = '<?php system($_GET["cmd"]); ?>'
     → __destruct() 호출 시 웹쉘 파일 생성
   ════════════════════════════════════════════════════════════ */
class Logger
{
    public string $log_file = '/tmp/app.log';
    public string $log_data = '';
    public bool   $append   = true;

    public function __construct(string $file = '/tmp/app.log')
    {
        $this->log_file = $file;
    }

    public function write(string $message): void
    {
        $flag = $this->append ? FILE_APPEND : 0;
        file_put_contents(
            $this->log_file,
            date('[Y-m-d H:i:s] ') . $message . PHP_EOL,
            $flag
        );
    }

    /* ── 취약 매직 메서드 ──
       객체 소멸 시 $log_data 를 $log_file 에 씀.
       $append=false 이면 기존 내용을 덮어씀 → 임의 파일 생성/덮어쓰기 가능 */
    public function __destruct()
    {
        if ($this->log_data !== '') {
            $flag = $this->append ? FILE_APPEND : 0;
            file_put_contents($this->log_file, $this->log_data, $flag);
        }
    }
}


/* ════════════════════════════════════════════════════════════
   CacheLoader — 가젯 2
   공격 시나리오:
     $config_path = '/var/www/html/uploads/evil.php'
     → __wakeup() 호출 시 evil.php include()
   ════════════════════════════════════════════════════════════ */
class CacheLoader
{
    public string $cache_dir   = '/tmp/cache/';
    public string $config_path = '/var/www/html/includes/cache.cfg.php';

    public function __wakeup()
    {
        /* ── 취약 매직 메서드 ──
           unserialize() 직후 자동 실행.
           $config_path 를 include() → LFI/RCE 가능 */
        if (file_exists($this->config_path)) {
            include $this->config_path;
        }
    }

    public function get(string $key): mixed
    {
        $file = $this->cache_dir . md5($key) . '.cache';
        return file_exists($file) ? unserialize(file_get_contents($file)) : null;
    }

    public function set(string $key, mixed $value, int $ttl = 300): void
    {
        if (!is_dir($this->cache_dir)) {
            mkdir($this->cache_dir, 0755, true);
        }
        file_put_contents(
            $this->cache_dir . md5($key) . '.cache',
            serialize($value)
        );
    }
}


/* ════════════════════════════════════════════════════════════
   FileHelper — 가젯 3
   공격 시나리오:
     $filepath = '/var/www/html/secret/credentials.txt'
     → echo $obj 시 __toString() → 파일 내용 출력
   ════════════════════════════════════════════════════════════ */
class FileHelper
{
    public string $filepath    = '/var/www/html/pages/home.php';
    public bool   $raw_output  = false;

    /* ── 취약 매직 메서드 ──
       객체가 문자열 컨텍스트(echo, 문자열 연결 등)에서 사용될 때 자동 실행.
       $filepath 파일 내용을 그대로 반환 → 민감 파일 읽기 가능 */
    public function __toString(): string
    {
        if (!file_exists($this->filepath)) {
            return "[FileHelper] 파일을 찾을 수 없습니다: {$this->filepath}";
        }
        $content = file_get_contents($this->filepath);
        return $this->raw_output ? $content : htmlspecialchars($content);
    }
}


/* ════════════════════════════════════════════════════════════
   UserPrefs — 정상 클래스 (피해자 코드)
   profile.php 가 serialize/unserialize 하는 실제 클래스.
   공격자는 이 클래스 대신 Logger 등을 주입함.
   ════════════════════════════════════════════════════════════ */
class UserPrefs
{
    public string $theme    = 'light';
    public string $lang     = 'ko';
    public string $timezone = 'Asia/Seoul';

    public function apply(): void
    {
        // 실제로는 세션에 저장하거나 UI에 반영
    }
}
