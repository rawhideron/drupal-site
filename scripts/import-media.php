<?php

/**
 * @file
 * Register the photos in public://photos as Image Media entities.
 *
 * Run (as www-data) from the host:
 *   docker compose exec -T --user www-data web drush php:script scripts/import-media.php
 *
 * The files are already in place (see scripts/import-images.sh); this creates
 * a File entity and an Image Media entity for each one. Media name and alt
 * text are the file name without its extension. The created date is the EXIF
 * capture date, falling back to the file's modification time when there is
 * none (or it is unusable).
 *
 * Safe to re-run: files that already have a Media entity are skipped. Nothing
 * is deleted.
 */

use Drupal\file\Entity\File;
use Drupal\media\Entity\Media;

$dir = 'public://photos';
$file_storage = \Drupal::entityTypeManager()->getStorage('file');
$media_storage = \Drupal::entityTypeManager()->getStorage('media');
$fs = \Drupal::service('file_system');

$names = array_keys(\Drupal::service('file_system')->scanDirectory($dir, '/\.(jpe?g|png|gif)$/i', ['recurse' => FALSE]));
sort($names);

$created = $skipped = $from_exif = $from_mtime = 0;

foreach ($names as $uri) {
  $files = $file_storage->loadByProperties(['uri' => $uri]);
  $file = $files ? reset($files) : NULL;

  if ($file && $media_storage->getQuery()->accessCheck(FALSE)
    ->condition('bundle', 'image')
    ->condition('field_media_image.target_id', $file->id())
    ->count()->execute()) {
    $skipped++;
    continue;
  }

  $path = $fs->realpath($uri);
  $timestamp = NULL;
  $exif = function_exists('exif_read_data') ? @exif_read_data($path) : FALSE;
  $taken = $exif['DateTimeOriginal'] ?? $exif['DateTime'] ?? '';
  if ($taken && ($date = DateTime::createFromFormat('Y:m:d H:i:s', $taken)) && $date->getTimestamp() > 0 && (int) $date->format('Y') > 1970) {
    $timestamp = $date->getTimestamp();
    $from_exif++;
  }
  else {
    $timestamp = filemtime($path);
    $from_mtime++;
  }

  if (!$file) {
    $file = File::create(['uri' => $uri, 'uid' => 1, 'status' => 1]);
    $file->save();
  }

  $title = pathinfo($uri, PATHINFO_FILENAME);
  Media::create([
    'bundle' => 'image',
    'name' => $title,
    'uid' => 1,
    'status' => 1,
    'created' => $timestamp,
    'field_media_image' => ['target_id' => $file->id(), 'alt' => $title],
  ])->save();

  $created++;
  if ($created % 50 === 0) {
    echo "$created created...\n";
  }
}

echo "Done: $created created ($from_exif with EXIF date, $from_mtime with file date), $skipped already had Media, " . count($names) . " files in photos/.\n";
