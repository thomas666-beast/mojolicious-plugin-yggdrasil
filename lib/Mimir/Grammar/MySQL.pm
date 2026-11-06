package Mimir::Grammar::MySQL;
use Moo;
extends 'Mimir::Grammar';

sub driver                    { 'mysql' }
sub quote_char                { '`' }
sub no_limit                  { '18446744073709551615' }
sub supports_ddl_transactions { 0 }

sub operator { my ($s, $op) = @_; $op = lc $op; $op =~ s/\bilike\b/like/; $op }
sub insert_verb { $_[1] ? 'insert ignore into' : 'insert into' }
sub compile_insert_default { my ($s, $q) = @_; 'insert into ' . $s->wrap($q->from) . ' () values ()' }
sub compile_lock { my ($s, $q) = @_; my $l = $q->get_lock // return ''; $l eq 'update' ? 'for update' : 'lock in share mode' }
sub compile_truncate { my ($s, $q) = @_; 'truncate table ' . $s->wrap($q->from) }
sub compile_rename { my ($s, $a, $b) = @_; 'rename table ' . $s->wrap($a) . ' to ' . $s->wrap($b) }

sub compile_upsert {
  my ($s, $q, $rows, $bind, $unique, $update) = @_;
  return $s->compile_insert($q, $rows, $bind, ignore => 1) unless @$update;
  return $s->compile_insert($q, $rows, $bind) . ' on duplicate key update '
    . CORE::join(', ', map { my $c = $s->wrap_segment($_); "$c = values($c)" } @$update);
}

sub compile_has_table   { my ($s, $t) = @_; ('select table_name as name from information_schema.tables where table_schema = database() and table_name = ?', $t) }
sub compile_columns     { my ($s, $t) = @_; ('select column_name as name from information_schema.columns where table_schema = database() and table_name = ?', $t) }
sub compile_list_tables { "select table_name as name from information_schema.tables where table_schema = database() and table_type = 'BASE TABLE'" }
sub fk_checks_off       { 'set foreign_key_checks = 0' }
sub fk_checks_on        { 'set foreign_key_checks = 1' }

sub create_suffix {
  my $s = shift;
  my $c = $s->config;
  my $cs = $c->{charset}   // 'utf8mb4';
  my $co = $c->{collation} // 'utf8mb4_unicode_ci';
  my $en = $c->{engine}    // 'InnoDB';
  return " default character set $cs collate $co engine = $en";
}

sub _unsigned { $_[1]->attrs->{unsigned} ? ' unsigned' : '' }

sub serial_definition {
  my ($s, $c) = @_;
  return ($c->type eq 'increments' ? 'int' : 'bigint') . ' unsigned not null auto_increment primary key';
}

sub compile_column {
  my ($s, $c) = @_;
  my $a = $c->attrs;
  my $sql = $s->SUPER::compile_column($c);
  $sql .= ' default null' if !$a->{auto_increment} && $a->{nullable} && !$a->{has_default} && $c->type =~ /^(?:timestamp)$/;
  if (defined $a->{comment}) { (my $e = $a->{comment}) =~ s/'/''/g; $sql .= " comment '$e'" }
  return $sql;
}

sub compile_add_column {
  my ($s, $table, $col) = @_;
  my $sql = $s->SUPER::compile_add_column($table, $col);
  $sql .= ' after ' . $s->wrap_segment($col->attrs->{after}) if defined $col->attrs->{after};
  return $sql;
}

sub type_integer       { 'int' . $_[0]->_unsigned($_[1]) }
sub type_big_integer   { 'bigint' . $_[0]->_unsigned($_[1]) }
sub type_small_integer { 'smallint' . $_[0]->_unsigned($_[1]) }
sub type_tiny_integer  { 'tinyint' . $_[0]->_unsigned($_[1]) }
sub type_boolean       { 'tinyint(1)' }
sub type_float         { 'float' . $_[0]->_unsigned($_[1]) }
sub type_double        { 'double' . $_[0]->_unsigned($_[1]) }
sub type_decimal       { my $a = $_[1]->attrs; "decimal($a->{precision}, $a->{scale})" . $_[0]->_unsigned($_[1]) }
sub type_medium_text   { 'mediumtext' }
sub type_long_text     { 'longtext' }
sub type_datetime      { 'datetime' }
sub type_uuid          { 'char(36)' }
sub type_enum {
  my ($s, $c) = @_;
  return 'enum(' . CORE::join(', ', map { (my $e = $_) =~ s/'/''/g; "'$e'" } @{$c->attrs->{allowed}}) . ')';
}

sub compile_cmd_drop_index {
  my ($s, $bp, $c) = @_;
  return 'drop index ' . $s->wrap_segment($c->{index}) . ' on ' . $s->wrap($bp->table);
}
sub compile_cmd_drop_foreign {
  my ($s, $bp, $c) = @_;
  return 'alter table ' . $s->wrap($bp->table) . ' drop foreign key ' . $s->wrap_segment($c->{index});
}

1;
