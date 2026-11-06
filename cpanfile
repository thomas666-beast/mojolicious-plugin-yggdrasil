requires 'perl', '5.016';
requires 'Moo', '2.003';
requires 'Mojolicious', '9.00';
requires 'DBI', '1.630';

recommends 'DBD::SQLite';
recommends 'DBD::Pg';
recommends 'DBD::mysql';      # or DBD::MariaDB

on test => sub {
  requires 'Test::More';
  requires 'DBD::SQLite', '1.66';
};
