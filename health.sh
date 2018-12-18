#!/bin/bash

test -e /tmp/ready && wget -qO- http://localhost/index.php/login | grep -q 'lost-password'
