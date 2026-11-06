package Yggdrasil::Grammar::SQLite;
use Moo;
use Carp ();
extends 'Yggdrasil::Grammar';

sub driver   { 'sqlite' }
sub no_limit { '-1' }

sub operator { my ($s, $op) = @_; $op = lc $op; $op =~ s/\bilike\b/like/; $op }
sub insert_verb { $_[1] ? 'insert or ignore into' : 'insert into' }

sub compile_has_table   { my ($s, $t) = @_; ("select name from sqlite_master where type = 'table' and name = ?", $t) }
sub compile_columns     { my ($s, $t) = @_; ('select name from pragma_table_info(?)', $t) }
sub compile_list_tables { "select name from sqlite_master where type = 'table' and name not like 'sqlite_%'" }
sub fk_checks_off       { 'pragma foreign_keys = off' }
sub fk_checks_on        { 'pragma foreign_keys = on' }

sub serial_definition   { 'integer not null primary key autoincrement' }
sub type_integer        { 'integer' }
sub type_tiny_integer   { 'tinyint' }
sub type_boolean        { 'tinyint(1)' }
sub type_datetime       { 'datetime' }
sub type_timestamp      { 'datetime' }
sub type_json           { 'text' }
sub type_uuid           { 'varchar(36)' }
sub type_double         { 'double' }

sub compile_cmd_primary      { Carp::croak('Mimir: SQLite cannot add a primary key to an existing table') }
sub compile_cmd_foreign      { Carp::croak('Mimir: SQLite cannot add a foreign key to an existing table; declare it in create()') }
sub compile_cmd_drop_foreign { Carp::croak('Mimir: SQLite cannot drop a foreign key') }

1;
