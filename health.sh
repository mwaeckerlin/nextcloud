#!/bin/bash

wget -qO- http://localhost/index.php/login | grep -q 'lost-password'
