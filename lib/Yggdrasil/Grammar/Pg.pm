package Yggdrasil::Grammar::Pg;
use Moo;
extends 'Yggdrasil::Grammar';

sub driver { 'pg' }

sub insert_ignore_suffix { ' on conflict do nothing' }
sub compile_lock { my ($s, $q) = @_; my $l = $q->get_lock // return ''; $l eq 'update' ? 'for update' : 'for share' }
sub compile_insert_get_id {
  my ($s, $q, $row, $bind, $pk) = @_;
  return $s->compile_insert($q, [$row], $bind) . ' returning ' . $s->wrap_segment($pk);
}
sub compile_truncate { my ($s, $q) = @_; 'truncate table ' . $s->wrap($q->from) . ' restart identity cascade' }

sub compile_has_table   { my ($s, $t) = @_; ('select table_name as name from information_schema.tables where table_schema = current_schema() and table_name = ?', $t) }
sub compile_columns     { my ($s, $t) = @_; ('select column_name as name from information_schema.columns where table_schema = current_schema() and table_name = ?', $t) }
sub compile_list_tables { "select table_name as name from information_schema.tables where table_schema = current_schema() and table_type = 'BASE TABLE'" }
sub compile_drop_table     { my ($s, $t) = @_; 'drop table ' . $s->wrap($t) . ' cascade' }
sub compile_drop_if_exists { my ($s, $t) = @_; 'drop table if exists ' . $s->wrap($t) . ' cascade' }

sub serial_definition { $_[1]->type eq 'increments' ? 'serial not null primary key' : 'bigserial not null primary key' }
sub type_tiny_integer { 'smallint' }
sub type_float        { 'real' }
sub type_datetime     { 'timestamp(0) without time zone' }
sub type_timestamp    { 'timestamp(0) without time zone' }
sub type_time         { 'time(0) without time zone' }
sub type_json         { 'jsonb' }
sub type_binary       { 'bytea' }

sub default_value {
  my ($s, $v, $c) = @_;
  return ($v ? 'true' : 'false') if defined $v && ref $v ne 'SCALAR' && $c->type eq 'boolean';
  return $s->SUPER::default_value($v, $c);
}

1;
