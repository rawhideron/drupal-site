<?php

// Database connection is configured via environment variables so no
// secrets are committed to git. See docker-compose.yml / .env.example.
$databases['default']['default'] = [
  'database' => getenv('DB_NAME') ?: 'drupal',
  'username' => getenv('DB_USER') ?: 'drupal',
  'password' => getenv('DB_PASSWORD') ?: '',
  'host' => getenv('DB_HOST') ?: 'db',
  'port' => getenv('DB_PORT') ?: '3306',
  'driver' => 'mysql',
  'prefix' => '',
];

$settings['hash_salt'] = getenv('HASH_SALT') ?: 'change-me-in-production';
$settings['file_private_path'] = 'sites/default/private';

include $app_root . '/../docker/proxy-https.settings.php';

if (file_exists(__DIR__ . '/settings.local.php')) {
  include __DIR__ . '/settings.local.php';
}
