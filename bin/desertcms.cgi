#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use DesertCMS::App;

DesertCMS::App->new->run;
