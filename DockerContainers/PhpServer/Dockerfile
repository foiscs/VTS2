# syntax=docker/dockerfile:1
# CVE-2024-2961 — PHP iconv OOB Write / Filter-chain RCE
# 취약 버전: PHP < 8.1.29 / < 8.2.20 / < 8.3.8
FROM php:8.1.0-apache

# iconv, mbstring 빌드 (--network=host: 호스트 네트워크로 apt 접근)
RUN --network=host apt-get update && apt-get install -y \
        libonig-dev \
        iproute2 \
    && docker-php-ext-install mbstring \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# allow_url_include 활성화 (취약 시나리오 재현용)
RUN echo "allow_url_include = On"  >> /usr/local/etc/php/php.ini \
 && echo "allow_url_fopen   = On"  >> /usr/local/etc/php/php.ini \
 && echo "display_errors    = Off" >> /usr/local/etc/php/php.ini

# Apache rewrite 허용
RUN a2enmod rewrite

COPY www/ /var/www/html/
RUN chown -R www-data:www-data /var/www/html/ \
 && chmod -R 755 /var/www/html/

EXPOSE 80
