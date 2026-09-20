<?php

// Included from every site's settings.php.
//
// Public HTTPS traffic arrives through Nginx Proxy Manager on host port 8443
// (see README) and is forwarded here over plain HTTP. Trust the proxy's
// X-Forwarded-Proto/-Port headers so Drupal builds https://host:8443 URLs
// instead of e.g. a login redirect to http://host/user/login, which lands on
// the wrong service. NPM must send X-Forwarded-Port (see README). Requests
// reaching Drupal directly (WEB_PORT) carry no such headers and are unaffected.
$settings['reverse_proxy'] = TRUE;
$settings['reverse_proxy_addresses'] = ['PRIVATE_SUBNETS'];
$settings['reverse_proxy_trusted_headers'] =
  \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_PROTO |
  \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_PORT;
