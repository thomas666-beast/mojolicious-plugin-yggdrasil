use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
  NAME         => 'Mojolicious::Plugin::Mimir',
  VERSION_FROM => 'lib/Mimir.pm',
  ABSTRACT     => 'Eloquent-style ORM, query builder and migrations for Mojolicious (SQLite, MySQL, PostgreSQL)',
  LICENSE      => 'perl_5',
  MIN_PERL_VERSION => '5.016',
  PREREQ_PM    => {
    'Moo'         => '2.003',
    'Mojolicious' => '9.00',
    'DBI'         => '1.630',
    'JSON::PP'    => 0,
  },
  TEST_REQUIRES => {
    'Test::More'      => 0,
    'DBD::SQLite'     => '1.66',
  },
  META_MERGE => {
    'meta-spec' => { version => 2 },
    recommends  => { 'DBD::Pg' => 0, 'DBD::mysql' => 0, 'DBD::MariaDB' => 0 },
  },
  test => { TESTS => 't/*.t' },
);
