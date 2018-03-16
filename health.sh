#!/bin/bash

wget -qO- http://localhost/login | grep -q 'lost-password'
