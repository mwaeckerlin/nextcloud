<?php
// Copied into the php-fpm container by the e2e test and requested over
// FastCGI, so it reports the limits a php-fpm worker really runs with.
header('Content-Type: application/json');
echo json_encode(array_combine(
    ['upload_max_filesize', 'post_max_size', 'memory_limit', 'max_input_time', 'max_execution_time'],
    array_map('ini_get', ['upload_max_filesize', 'post_max_size', 'memory_limit', 'max_input_time', 'max_execution_time'])
));
