package Yggdrasil::Grammar;
use Moo;
use Carp ();
use Scalar::Util qw(blessed looks_like_number);
use Yggdrasil::Util qw(index_name);

has config => (is => 'ro', default => sub { +{} });

sub driver                    { 'generic' }
sub quote_char                { '"' }
sub no_limit                  { undef }
sub supports_ddl_transactions { 1 }
sub compile_lock              { '' }

my %OPS = map { $_ => 1 } ('=', '<', '>', '<=', '>=', '<>', '!=', '<=>', 'like', 'not like',
  'ilike', 'not ilike', 'regexp', 'not regexp', 'rlike', '~', '~*', '!~', '!~*');
sub valid_operator { $OPS{lc $_[1]} ? 1 : 0 }
sub operator       { lc $_[1] }

# ---- identifiers & values -------------------------------------------------------

sub wrap_segment {
  my ($s, $v) = @_;
  return $v if $v eq '*';
  my $q = $s->quote_char;
  (my $e = $v) =~ s/\Q$q\E/$q$q/g;
  return "$q$e$q";
}

sub wrap {
  my ($s, $v) = @_;
  return $$v if ref $v eq 'SCALAR';
  Carp::croak('Mimir: invalid identifier') if !defined $v || ref $v;
  return $s->wrap($1) . ' as ' . $s->wrap_segment($2) if $v =~ /^(.+?)\s+as\s+(.+)$/i;
  return CORE::join('.', map { $s->wrap_segment($_) } split /\./, $v);
}

sub columnize { my ($s, $cols) = @_; CORE::join(', ', map { $s->wrap($_) } @$cols) }

sub value {
  my ($s, $v, $bind) = @_;
  if (ref $v eq 'SCALAR') { return $$v }
  if (ref $v eq 'REF' && ref $$v eq 'ARRAY') {
    my ($sql, @b) = @{$$v};
    push @$bind, @b;
    return $sql;
  }
  return '(' . $s->compile_select($v, $bind) . ')' if blessed $v && $v->isa('Yggdrasil::Query');
  Carp::croak('Mimir: cannot bind a ' . ref($v) . ' reference') if ref $v && !blessed $v;
  push @$bind, defined $v && blessed $v ? "$v" : $v;
  return '?';
}

sub column {
  my ($s, $c, $bind) = @_;
  return $s->value($c, $bind) if ref $c eq 'REF';
  return $s->wrap($c);
}

# ---- SELECT -----------------------------------------------------------------

sub compile_select {
  my ($s, $q, $bind) = @_;
  Carp::croak('Mimir: no table specified') unless defined $q->from;
  my $cols = $q->columns;
  my @p = ('select ' . ($q->is_distinct ? 'distinct ' : '')
    . ($cols && @$cols ? CORE::join(', ', map { $s->column($_, $bind) } @$cols) : '*'));
  push @p, 'from ' . $s->wrap($q->from);
  push @p, $s->compile_joins($q, $bind) if @{$q->joins};
  if (@{$q->wheres}) {
    my $w = $s->wheres_sql($q->wheres, $bind);
    push @p, "where $w" if length $w;
  }
  push @p, 'group by ' . CORE::join(', ', map { $s->column($_, $bind) } @{$q->groups}) if @{$q->groups};
  if (@{$q->havings}) {
    my $h = $s->wheres_sql($q->havings, $bind);
    push @p, "having $h" if length $h;
  }
  if (@{$q->orders}) {
    push @p, 'order by ' . CORE::join(', ', map {
      if (exists $_->{raw}) { push @$bind, @{$_->{bindings} || []}; $_->{raw} }
      else { $s->wrap($_->{column}) . ' ' . $_->{direction} }
    } @{$q->orders});
  }
  my $lim = $s->compile_limit($q);
  push @p, $lim if length $lim;
  my $lock = $s->compile_lock($q);
  push @p, $lock if length $lock;
  return CORE::join(' ', @p);
}

sub compile_joins {
  my ($s, $q, $bind) = @_;
  return CORE::join(' ', map {
    my $j = $_;
    my $sql = $j->{type} . ' join ' . $s->wrap($j->{table});
    if ($j->{clause}) {
      my $on = $s->wheres_sql($j->{clause}->wheres, $bind);
      $sql .= " on $on" if length $on;
    }
    $sql;
  } @{$q->joins});
}

sub compile_limit {
  my ($s, $q) = @_;
  my ($l, $o) = ($q->get_limit, $q->get_offset);
  return '' unless defined $l || defined $o;
  $l = $s->no_limit if defined $o && !defined $l;
  my @p;
  push @p, "limit $l"   if defined $l;
  push @p, "offset $o"  if defined $o;
  return CORE::join(' ', @p);
}

# ---- WHERE ------------------------------------------------------------------

sub wheres_sql {
  my ($s, $wheres, $bind) = @_;
  my $sql = '';
  for my $w (@$wheres) {
    my $m = $s->can('_where_' . $w->{type}) or Carp::croak("Mimir: unknown where type $w->{type}");
    my $part = $s->$m($w, $bind);
    next unless defined $part && length $part;
    $sql .= (length $sql ? " $w->{boolean} " : '') . $part;
  }
  return $sql;
}

sub _where_basic {
  my ($s, $w, $bind) = @_;
  return $s->column($w->{column}, $bind) . ' ' . $s->operator($w->{operator}) . ' ' . $s->value($w->{value}, $bind);
}

sub _where_in {
  my ($s, $w, $bind) = @_;
  my $not = $w->{not} ? 'not ' : '';
  my $v = $w->{values};
  my $col = $s->column($w->{column}, $bind);
  return "$col ${not}in (" . $s->compile_select($v, $bind) . ')' if blessed $v && $v->isa('Yggdrasil::Query');
  return $w->{not} ? '1 = 1' : '0 = 1' unless @$v;
  return "$col ${not}in (" . CORE::join(', ', map { $s->value($_, $bind) } @$v) . ')';
}

sub _where_null {
  my ($s, $w, $bind) = @_;
  return $s->column($w->{column}, $bind) . ' is ' . ($w->{not} ? 'not ' : '') . 'null';
}

sub _where_between {
  my ($s, $w, $bind) = @_;
  my $col = $s->column($w->{column}, $bind);
  return "$col " . ($w->{not} ? 'not ' : '') . 'between ' . $s->value($w->{values}[0], $bind) . ' and ' . $s->value($w->{values}[1], $bind);
}

sub _where_column {
  my ($s, $w) = @_;
  return $s->wrap($w->{first}) . ' ' . $s->operator($w->{operator}) . ' ' . $s->wrap($w->{second});
}

sub _where_raw {
  my ($s, $w, $bind) = @_;
  push @$bind, @{$w->{bindings} || []};
  return $w->{sql};
}

sub _where_nested {
  my ($s, $w, $bind) = @_;
  my $sql = $s->wheres_sql($w->{query}->wheres, $bind);
  return length $sql ? "($sql)" : '';
}

sub _where_exists {
  my ($s, $w, $bind) = @_;
  return ($w->{not} ? 'not ' : '') . 'exists (' . $s->compile_select($w->{query}, $bind) . ')';
}

# ---- writes -----------------------------------------------------------------

sub insert_verb { 'insert into' }
sub insert_ignore_suffix { '' }
sub compile_insert_default { my ($s, $q) = @_; 'insert into ' . $s->wrap($q->from) . ' default values' }

sub compile_insert {
  my ($s, $q, $rows, $bind, %o) = @_;
  my @cols = sort keys %{$rows->[0]};
  return $s->compile_insert_default($q) unless @cols;
  my $sql = $s->insert_verb($o{ignore}) . ' ' . $s->wrap($q->from)
    . ' (' . CORE::join(', ', map { $s->wrap_segment($_) } @cols) . ') values '
    . CORE::join(', ', map {
        my $r = $_;
        '(' . CORE::join(', ', map { $s->value($r->{$_}, $bind) } @cols) . ')';
      } @$rows);
  $sql .= $s->insert_ignore_suffix if $o{ignore};
  return $sql;
}

sub compile_insert_get_id { my ($s, $q, $row, $bind) = @_; $s->compile_insert($q, [$row], $bind) }

sub compile_upsert {
  my ($s, $q, $rows, $bind, $unique, $update) = @_;
  my $sql = $s->compile_insert($q, $rows, $bind);
  my $target = CORE::join(', ', map { $s->wrap_segment($_) } @$unique);
  return $sql . " on conflict ($target) do nothing" unless @$update;
  return $sql . " on conflict ($target) do update set "
    . CORE::join(', ', map { my $c = $s->wrap_segment($_); "$c = excluded.$c" } @$update);
}

sub compile_update {
  my ($s, $q, $values, $bind) = @_;
  Carp::croak('Mimir: update with joins is not supported') if @{$q->joins};
  my @sets = map {
    my ($c) = /([^.]+)$/;
    $s->wrap_segment($c) . ' = ' . $s->value($values->{$_}, $bind);
  } sort keys %$values;
  my $sql = 'update ' . $s->wrap($q->from) . ' set ' . CORE::join(', ', @sets);
  my $w = @{$q->wheres} ? $s->wheres_sql($q->wheres, $bind) : '';
  return length $w ? "$sql where $w" : $sql;
}

sub compile_delete {
  my ($s, $q, $bind) = @_;
  Carp::croak('Mimir: delete with joins is not supported') if @{$q->joins};
  my $sql = 'delete from ' . $s->wrap($q->from);
  my $w = @{$q->wheres} ? $s->wheres_sql($q->wheres, $bind) : '';
  return length $w ? "$sql where $w" : $sql;
}

sub compile_truncate { my ($s, $q) = @_; return ('delete from ' . $s->wrap($q->from)) }

# ---- schema introspection (overridden per driver) -----------------------------

sub compile_has_table      { Carp::croak('not implemented') }
sub compile_columns        { Carp::croak('not implemented') }
sub compile_list_tables    { Carp::croak('not implemented') }
sub fk_checks_off          { () }
sub fk_checks_on           { () }
sub compile_drop_table     { my ($s, $t) = @_; 'drop table ' . $s->wrap($t) }
sub compile_drop_if_exists { my ($s, $t) = @_; 'drop table if exists ' . $s->wrap($t) }
sub compile_rename         { my ($s, $a, $b) = @_; 'alter table ' . $s->wrap($a) . ' rename to ' . $s->wrap($b) }

# ---- DDL ----------------------------------------------------------------------

sub compile_blueprint {
  my ($s, $bp) = @_;
  my @cmds = @{$bp->commands};
  for my $c (@{$bp->columns}) {
    my $a = $c->attrs;
    push @cmds, { name => 'primary', columns => [$c->name] } if $a->{primary} && !$a->{auto_increment};
    push @cmds, { name => 'unique',  columns => [$c->name] } if $a->{unique};
    push @cmds, { name => 'index',   columns => [$c->name] } if $a->{index};
    push @cmds, { name => 'foreign', fk => $a->{fk} }        if $a->{fk};
  }
  return $bp->create ? $s->compile_create($bp, \@cmds) : $s->compile_alter($bp, \@cmds);
}

sub compile_create {
  my ($s, $bp, $cmds) = @_;
  my @defs = map { $s->compile_column($_) } @{$bp->columns};
  for my $c (@$cmds) {
    push @defs, 'primary key (' . $s->columnize($c->{columns}) . ')' if $c->{name} eq 'primary';
    push @defs, $s->compile_foreign($bp->table, $c->{fk})            if $c->{name} eq 'foreign';
  }
  return (
    'create table ' . $s->wrap($bp->table) . ' (' . CORE::join(', ', @defs) . ')' . $s->create_suffix($bp),
    (map { $s->compile_cmd_index($bp, $_) } grep { $_->{name} eq 'index' }  @$cmds),
    (map { $s->compile_cmd_unique($bp, $_) } grep { $_->{name} eq 'unique' } @$cmds),
  );
}

sub create_suffix { '' }

sub compile_alter {
  my ($s, $bp, $cmds) = @_;
  my @sql = map { $s->compile_add_column($bp->table, $_) } @{$bp->columns};
  for my $c (@$cmds) {
    my $m = $s->can('compile_cmd_' . $c->{name}) or Carp::croak("Mimir: unsupported command $c->{name}");
    push @sql, $s->$m($bp, $c);
  }
  return @sql;
}

sub compile_add_column {
  my ($s, $table, $col) = @_;
  return 'alter table ' . $s->wrap($table) . ' add column ' . $s->compile_column($col);
}

sub compile_column {
  my ($s, $c) = @_;
  my $a = $c->attrs;
  my $sql = $s->wrap_segment($c->name) . ' ';
  return $sql . $s->serial_definition($c) if $a->{auto_increment};
  $sql .= $s->column_type($c);
  $sql .= $a->{nullable} ? ' null' : ' not null';
  $sql .= ' default ' . $s->default_value($a->{default}, $c) if $a->{has_default};
  return $sql;
}

sub column_type {
  my ($s, $c) = @_;
  my $m = $s->can('type_' . $c->type) or Carp::croak('Mimir: unknown column type ' . $c->type);
  return $s->$m($c);
}

sub default_value {
  my ($s, $v, $c) = @_;
  return 'null' unless defined $v;
  return $$v if ref $v eq 'SCALAR';
  return ($v ? '1' : '0') if $c->type eq 'boolean';
  return $v if looks_like_number($v) && $c->type =~ /integer|float|double|decimal/;
  (my $e = $v) =~ s/'/''/g;
  return "'$e'";
}

sub type_string       { 'varchar(' . ($_[1]->attrs->{length} // 255) . ')' }
sub type_char         { 'char(' . ($_[1]->attrs->{length} // 255) . ')' }
sub type_text         { 'text' }
sub type_medium_text  { $_[0]->type_text($_[1]) }
sub type_long_text    { $_[0]->type_text($_[1]) }
sub type_integer      { 'integer' }
sub type_big_integer  { 'bigint' }
sub type_small_integer{ 'smallint' }
sub type_tiny_integer { 'smallint' }
sub type_boolean      { 'boolean' }
sub type_float        { 'float' }
sub type_double       { 'double precision' }
sub type_decimal      { my $a = $_[1]->attrs; "numeric($a->{precision}, $a->{scale})" }
sub type_date         { 'date' }
sub type_datetime     { 'timestamp' }
sub type_timestamp    { 'timestamp' }
sub type_time         { 'time' }
sub type_json         { 'json' }
sub type_uuid         { 'uuid' }
sub type_binary       { 'blob' }
sub type_enum {
  my ($s, $c) = @_;
  my $list = CORE::join(', ', map { (my $e = $_) =~ s/'/''/g; "'$e'" } @{$c->attrs->{allowed}});
  return 'varchar(255) check (' . $s->wrap_segment($c->name) . " in ($list))";
}

sub compile_foreign {
  my ($s, $table, $fk) = @_;
  my $name = $fk->fk_name // index_name($table, $fk->columns, 'foreign');
  my $sql = 'constraint ' . $s->wrap_segment($name) . ' foreign key (' . $s->columnize($fk->columns) . ') references '
    . $s->wrap($fk->table // Carp::croak('Mimir: foreign key needs ->on($table)')) . ' (' . $s->columnize($fk->ref_columns) . ')';
  $sql .= ' on delete ' . $fk->delete_action if $fk->delete_action;
  $sql .= ' on update ' . $fk->update_action if $fk->update_action;
  return $sql;
}

sub compile_cmd_index {
  my ($s, $bp, $c) = @_;
  my $n = $c->{index} // index_name($bp->table, $c->{columns}, 'index');
  return 'create index ' . $s->wrap_segment($n) . ' on ' . $s->wrap($bp->table) . ' (' . $s->columnize($c->{columns}) . ')';
}

sub compile_cmd_unique {
  my ($s, $bp, $c) = @_;
  my $n = $c->{index} // index_name($bp->table, $c->{columns}, 'unique');
  return 'create unique index ' . $s->wrap_segment($n) . ' on ' . $s->wrap($bp->table) . ' (' . $s->columnize($c->{columns}) . ')';
}

sub compile_cmd_primary     { my ($s, $bp, $c) = @_; 'alter table ' . $s->wrap($bp->table) . ' add primary key (' . $s->columnize($c->{columns}) . ')' }
sub compile_cmd_foreign     { my ($s, $bp, $c) = @_; 'alter table ' . $s->wrap($bp->table) . ' add ' . $s->compile_foreign($bp->table, $c->{fk}) }
sub compile_cmd_drop_index  { my ($s, $bp, $c) = @_; 'drop index ' . $s->wrap_segment($c->{index}) }
sub compile_cmd_drop_unique { shift->compile_cmd_drop_index(@_) }
sub compile_cmd_drop_foreign{ my ($s, $bp, $c) = @_; 'alter table ' . $s->wrap($bp->table) . ' drop constraint ' . $s->wrap_segment($c->{index}) }
sub compile_cmd_drop_column {
  my ($s, $bp, $c) = @_;
  return map { 'alter table ' . $s->wrap($bp->table) . ' drop column ' . $s->wrap_segment($_) } @{$c->{columns}};
}
sub compile_cmd_rename_column {
  my ($s, $bp, $c) = @_;
  return 'alter table ' . $s->wrap($bp->table) . ' rename column ' . $s->wrap_segment($c->{from}) . ' to ' . $s->wrap_segment($c->{to});
}

1;
