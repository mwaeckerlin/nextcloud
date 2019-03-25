#!/bin/bash

test -e /tmp/ready && wget -qO- http://localhost${WEBROOT}/index.php/login | grep -q 'lost-password' && wget -qO- http://localhost${WEBROOT}/status.php | grep -qP '^(?=.*"installed":true)(?=.*"maintenance":false)(?=.*"needsDbUpgrade":false)'
