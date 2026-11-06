package Yggdrasil::Query;
use Moo;
use Carp ();
use Scalar::Util qw(blessed looks_like_number refaddr);
use Mojo::Collection;
use Yggdrasil::Paginator;
use Yggdrasil::Exception;

our $AUTOLOAD;

has connection => (is => 'ro', required => 1);
has model      => (is => 'rw');
has _from      => (is => 'rw', init_arg => 'from');
has columns    => (is => 'rw');
has _distinct  => (is => 'rw', init_arg => 'distinct');
has joins      => (is => 'rw', default => sub { [] });
has wheres     => (is => 'rw', default => sub { [] });
has groups     => (is => 'rw', default => sub { [] });
has havings    => (is => 'rw', default => sub { [] });
has orders     => (is => 'rw', default => sub { [] });
has _limit     => (is => 'rw', init_arg => 'limit');
has _offset    => (is => 'rw', init_arg => 'offset');
has _lock      => (is => 'rw', init_arg => 'lock_mode');
has eager      => (is => 'rw', default => sub { [] });

sub from         { my $s = shift; return $s->_from unless @_; $s->_from(shift); $s }
sub is_distinct  { $_[0]->_distinct }
sub get_limit    { $_[0]->_limit }
sub get_offset   { $_[0]->_offset }
sub get_lock     { $_[0]->_lock }
sub grammar      { $_[0]->connection->grammar }

sub new_query { Yggdrasil::Query->new(connection => $_[0]->connection) }

sub clone {
  my $s = shift;
  return (ref $s)->new(
    connection => $s->connection, model => $s->model, from => $s->from,
    columns => ($s->columns ? [@{$s->columns}] : undef), distinct => $s->is_distinct,
    joins => [@{$s->joins}], wheres => [@{$s->wheres}], groups => [@{$s->groups}],
    havings => [@{$s->havings}], orders => [@{$s->orders}],
    limit => $s->get_limit, offset => $s->get_offset, lock_mode => $s->get_lock,
    eager => [@{$s->eager}],
  );
}

# ---- SELECT clause -----------------------------------------------------------------

sub select     { my $s = shift; $s->columns([map { ref $_ eq 'ARRAY' ? @$_ : $_ } @_]); $s }
sub add_select { my $s = shift; $s->columns([@{$s->columns || []}, @_]); $s }
sub select_raw { my ($s, $sql, @b) = @_; $s->add_select(\[$sql, @b]) }
sub distinct   { my $s = shift; $s->_distinct(@_ ? $_[0] : 1); $s }

# ---- WHERE clause --------------------------------------------------------------------

sub where    { shift->_where('and', @_) }
sub or_where { shift->_where('or', @_) }

sub _where {
  my ($s, $bool, @a) = @_;
  if (@a == 1) {
    my $c = $a[0];
    return $s->_nested($bool, $c) if ref $c eq 'CODE';
    return $s->_where_raw($bool, $$c) if ref $c eq 'SCALAR';
    if (ref $c eq 'HASH') {
      my @keys = sort keys %$c;
      if ($bool eq 'or') {
        return $s->_nested('or', sub { my $q = shift; $q->where($_ => $c->{$_}) for @keys });
      }
      $s->where($_ => $c->{$_}) for @keys;
      return $s;
    }
    Carp::croak('Yggdrasil: where() needs column/value, a hashref or a coderef');
  }
  my ($col, $op, $val) = @a == 2 ? ($a[0], '=', $a[1]) : @a == 3 ? @a : Carp::croak('Yggdrasil: where() takes 1 to 3 arguments');
  Carp::croak('Yggdrasil: invalid operator "' . ($op // 'undef') . '"') unless $s->grammar->valid_operator($op);
  $op = lc $op;
  if (!defined $val) {
    Carp::croak("Yggdrasil: operator '$op' cannot be used with undef") unless $op =~ /^(?:=|!=|<>)$/;
    return $s->_where_null($col, $bool, $op eq '=' ? 0 : 1);
  }
  if (ref $val eq 'ARRAY') {
    Carp::croak("Yggdrasil: operator '$op' cannot be used with an array") unless $op =~ /^(?:=|!=|<>)$/;
    return $s->_where_in($col, $val, $bool, $op eq '=' ? 0 : 1);
  }
  if (ref $val eq 'CODE') { my $q = $s->new_query; $val->($q); $val = $q }
  push @{$s->wheres}, { type => 'basic', column => $col, operator => $op, value => $val, boolean => $bool };
  return $s;
}

sub _nested {
  my ($s, $bool, $cb) = @_;
  my $q = $s->new_query;
  $cb->($q);
  push @{$s->wheres}, { type => 'nested', query => $q, boolean => $bool };
  return $s;
}

sub _where_raw  { my ($s, $bool, $sql, @b) = @_; push @{$s->wheres}, { type => 'raw', sql => $sql, bindings => \@b, boolean => $bool }; $s }
sub where_raw    { my $s = shift; $s->_where_raw('and', @_) }
sub or_where_raw { my $s = shift; $s->_where_raw('or', @_) }

sub _where_in {
  my ($s, $col, $vals, $bool, $not) = @_;
  if (ref $vals eq 'CODE') { my $q = $s->new_query; $vals->($q); $vals = $q }
  push @{$s->wheres}, { type => 'in', column => $col, values => $vals, boolean => $bool, not => $not };
  return $s;
}
sub where_in         { $_[0]->_where_in($_[1], $_[2], 'and', 0) }
sub or_where_in      { $_[0]->_where_in($_[1], $_[2], 'or',  0) }
sub where_not_in     { $_[0]->_where_in($_[1], $_[2], 'and', 1) }
sub or_where_not_in  { $_[0]->_where_in($_[1], $_[2], 'or',  1) }

sub _where_null {
  my ($s, $col, $bool, $not) = @_;
  push @{$s->wheres}, { type => 'null', column => $col, boolean => $bool, not => $not };
  return $s;
}
sub where_null        { $_[0]->_where_null($_[1], 'and', 0) }
sub or_where_null     { $_[0]->_where_null($_[1], 'or',  0) }
sub where_not_null    { $_[0]->_where_null($_[1], 'and', 1) }
sub or_where_not_null { $_[0]->_where_null($_[1], 'or',  1) }

sub _where_between {
  my ($s, $col, $v, $bool, $not) = @_;
  Carp::croak('Yggdrasil: between needs [min, max]') unless ref $v eq 'ARRAY' && @$v == 2;
  push @{$s->wheres}, { type => 'between', column => $col, values => $v, boolean => $bool, not => $not };
  return $s;
}
sub where_between     { $_[0]->_where_between($_[1], $_[2], 'and', 0) }
sub or_where_between  { $_[0]->_where_between($_[1], $_[2], 'or',  0) }
sub where_not_between { $_[0]->_where_between($_[1], $_[2], 'and', 1) }

sub _where_column {
  my ($s, $bool, $a, $op, $b) = @_;
  ($op, $b) = ('=', $op) unless defined $b;
  Carp::croak("Yggdrasil: invalid operator '$op'") unless $s->grammar->valid_operator($op);
  push @{$s->wheres}, { type => 'column', first => $a, operator => $op, second => $b, boolean => $bool };
  return $s;
}
sub where_column    { my $s = shift; $s->_where_column('and', @_) }
sub or_where_column { my $s = shift; $s->_where_column('or', @_) }
sub on              { my $s = shift; $s->_where_column('and', @_) }
sub or_on           { my $s = shift; $s->_where_column('or', @_) }

sub _where_exists {
  my ($s, $q, $bool, $not) = @_;
  if (ref $q eq 'CODE') { my $cb = $q; $q = $s->new_query; $cb->($q) }
  push @{$s->wheres}, { type => 'exists', query => $q, boolean => $bool, not => $not };
  return $s;
}
sub where_exists     { $_[0]->_where_exists($_[1], 'and', 0) }
sub where_not_exists { $_[0]->_where_exists($_[1], 'and', 1) }

sub when {
  my ($s, $cond, $cb, $else) = @_;
  if ($cond) { $cb->($s, $cond) } elsif ($else) { $else->($s, $cond) }
  return $s;
}
sub tap { my ($s, $cb) = @_; $cb->($s); $s }

# ---- joins, grouping, ordering, limits -------------------------------------------------

sub _join {
  my ($s, $type, $table, @a) = @_;
  my $clause = $s->new_query;
  if    (ref $a[0] eq 'CODE') { $a[0]->($clause) }
  elsif (@a == 2)            { $clause->where_column($a[0], '=', $a[1]) }
  elsif (@a == 3)            { $clause->where_column(@a) }
  elsif ($type ne 'cross')   { Carp::croak('Yggdrasil: join needs a condition') }
  push @{$s->joins}, { type => $type, table => $table, clause => $clause };
  return $s;
}
sub left_join  { my $s = shift; $s->_join('left',  @_) }
sub right_join { my $s = shift; $s->_join('right', @_) }
sub cross_join { my $s = shift; $s->_join('cross', @_) }

sub group_by { my $s = shift; push @{$s->groups}, map { ref $_ eq 'ARRAY' ? @$_ : $_ } @_; $s }

sub _having {
  my ($s, $bool, $col, $op, $val) = @_;
  ($op, $val) = ('=', $op) if @_ == 4;
  Carp::croak("Yggdrasil: invalid operator '$op'") unless $s->grammar->valid_operator($op);
  push @{$s->havings}, { type => 'basic', column => $col, operator => lc $op, value => $val, boolean => $bool };
  return $s;
}
sub having        { my $s = shift; $s->_having('and', @_) }
sub or_having     { my $s = shift; $s->_having('or', @_) }
sub having_raw    { my ($s, $sql, @b) = @_; push @{$s->havings}, { type => 'raw', sql => $sql, bindings => \@b, boolean => 'and' }; $s }

sub order_by {
  my ($s, $col, $dir) = @_;
  $dir = lc($dir // 'asc');
  Carp::croak("Yggdrasil: invalid order direction '$dir'") unless $dir eq 'asc' || $dir eq 'desc';
  push @{$s->orders}, { column => $col, direction => $dir };
  return $s;
}
sub order_by_desc { $_[0]->order_by($_[1], 'desc') }
sub order_by_raw  { my ($s, $sql, @b) = @_; push @{$s->orders}, { raw => $sql, bindings => \@b }; $s }
sub latest        { $_[0]->order_by($_[1] // 'created_at', 'desc') }
sub oldest        { $_[0]->order_by($_[1] // 'created_at', 'asc') }
sub reorder       { $_[0]->orders([]); $_[0] }

sub _int { my $n = shift; Carp::croak("Yggdrasil: '$n' is not a non-negative integer") unless $n =~ /^\d+$/; 0 + $n }
sub limit  { my ($s, $n) = @_; $s->_limit(defined $n ? _int($n) : undef); $s }
sub offset { my ($s, $n) = @_; $s->_offset(defined $n ? _int($n) : undef); $s }
sub take   { shift->limit(@_) }
sub skip   { shift->offset(@_) }
sub for_page {
  my ($s, $page, $per) = @_;
  $page = 1 if !$page || $page < 1;
  $per ||= 15;
  return $s->limit($per)->offset(($page - 1) * $per);
}

sub lock_for_update { $_[0]->_lock('update'); $_[0] }
sub shared_lock     { $_[0]->_lock('share');  $_[0] }

sub include {
  my ($s, @specs) = @_;
  for (my $i = 0; $i < @specs; $i++) {
    my $x = $specs[$i];
    if    (ref $x eq 'HASH')  { push @{$s->eager}, [$_, $x->{$_}] for sort keys %$x }
    elsif (ref $x eq 'ARRAY') { $s->include(@$x) }
    else {
      my $cb = ref $specs[$i + 1] eq 'CODE' ? $specs[++$i] : undef;
      push @{$s->eager}, [$x, $cb];
    }
  }
  return $s;
}

# ---- compiling -------------------------------------------------------------------------------

sub compile {
  my $s = shift;
  my @bind;
  my $sql = $s->grammar->compile_select($s, \@bind);
  return ($sql, \@bind);
}
sub to_sql   { my ($sql) = $_[0]->compile; $sql }
sub bindings { my (undef, $b) = $_[0]->compile; $b }

# ---- reading -----------------------------------------------------------------------------------

sub _rows {
  my $s = shift;
  my ($sql, $b) = $s->compile;
  return $s->connection->select_all($sql, @$b);
}

sub get {
  my ($s, @cols) = @_;
  my $q = $s;
  my $m = $s->model;
  if (@cols) { $q = $s->clone->select(@cols) }
  elsif ($m && @{$s->joins} && !$s->columns) { $q = $s->clone->select($s->from . '.*') }
  my $rows = $q->_rows;
  return Mojo::Collection->new(@$rows) unless $m;
  my $conn = $s->connection->name;
  my @items = map { $m->_hydrate($_, $conn) } @$rows;
  $m->eager_load_relations(\@items, $s->eager) if @items && @{$s->eager};
  return Mojo::Collection->new(@items);
}

sub first { my ($s, @cols) = @_; return $s->clone->limit(1)->get(@cols)->first }

sub _pk_col {
  my $s = shift;
  return ($s->model->table . '.' . $s->model->primary_key) if $s->model;
  return 'id';
}

sub find {
  my ($s, $id) = @_;
  return Mojo::Collection->new unless defined $id;
  return $s->clone->where_in($s->_pk_col, $id)->get if ref $id eq 'ARRAY';
  return $s->clone->where($s->_pk_col, $id)->first;
}

sub find_or_fail {
  my ($s, $id) = @_;
  my $r = $s->find($id);
  return $r if defined $r;
  my $m = $s->model // 'table ' . $s->from;
  Yggdrasil::Exception->throw(message => "No query results for $m [" . ($id // 'undef') . ']', type => 'model_not_found', model => $s->model);
}

sub first_or_fail {
  my $s = shift;
  my $r = $s->first(@_);
  return $r if defined $r;
  Yggdrasil::Exception->throw(message => 'No query results for ' . ($s->model // 'table ' . $s->from), type => 'model_not_found', model => $s->model);
}

sub value {
  my ($s, $col) = @_;
  my $r = $s->clone->select($col)->limit(1)->_rows->[0] or return undef;
  my ($v) = values %$r;
  return $v;
}

sub pluck {
  my ($s, $col, $key) = @_;
  my $rows = $s->clone->select($key ? ($col, $key) : ($col))->_rows;
  my ($c) = $col =~ /([^.\s]+)$/;
  if ($key) {
    my ($k) = $key =~ /([^.\s]+)$/;
    return +{ map { $_->{$k} => $_->{$c} } @$rows };
  }
  return Mojo::Collection->new(map { $_->{$c} } @$rows);
}

sub _aggregate {
  my ($s, $fn, $col) = @_;
  $col //= '*';
  my $g = $s->grammar;
  my $row;
  if ($fn eq 'count' && (@{$s->groups} || @{$s->havings} || $s->is_distinct || defined $s->get_limit || defined $s->get_offset)) {
    my @b;
    my $inner = $g->compile_select($s->clone->reorder, \@b);
    $row = $s->connection->select_one("select count(*) as aggregate from ($inner) as yggdrasil_aggregate", @b);
  }
  else {
    my $q = $s->clone->reorder->select(\($fn . '(' . $g->wrap($col) . ') as aggregate'));
    my ($sql, $b) = $q->compile;
    $row = $s->connection->select_one($sql, @$b);
  }
  my $v = $row ? $row->{aggregate} : undef;
  return looks_like_number($v) ? 0 + $v : $v;
}
sub count { my ($s, $c) = @_; $s->_aggregate('count', $c) // 0 }
sub sum   { my ($s, $c) = @_; $s->_aggregate('sum', $c) // 0 }
sub avg   { $_[0]->_aggregate('avg', $_[1]) }
sub min   { $_[0]->_aggregate('min', $_[1]) }
sub max   { $_[0]->_aggregate('max', $_[1]) }

sub doesnt_exist { !$_[0]->exists }

sub paginate {
  my ($s, $per, $page) = @_;
  $per  ||= ($s->model ? $s->model->per_page : 15);
  $page ||= 1;
  $page = 1 if $page !~ /^\d+$/ || $page < 1;
  my $total = $s->count;
  my $items = $total ? $s->clone->for_page($page, $per)->get : Mojo::Collection->new;
  return Yggdrasil::Paginator->new(items => $items, total => $total, per_page => $per, current_page => $page);
}

# Return exactly 0 from the callback to stop early.
sub chunk {
  my ($s, $size, $cb) = @_;
  my $page = 1;
  while (1) {
    my $res = $s->clone->for_page($page, $size)->get;
    last unless @$res;
    my $r = $cb->($res, $page);
    last if defined $r && !ref $r && $r eq '0';
    last if @$res < $size;
    $page++;
  }
  return $s;
}

# ---- writing --------------------------------------------------------------------------------------

sub _rows_arg {
  my ($s, $d) = @_;
  my @rows = ref $d eq 'ARRAY' ? @$d : ($d);
  Carp::croak('Yggdrasil: nothing to insert') unless @rows;
  if (my $m = $s->model) {
    @rows = map { my $r = $_; +{ map { $_ => $m->cast_for_storage($_, $r->{$_}) } keys %$r } } @rows;
  }
  my %cols = map { $_ => 1 } map { keys %$_ } @rows;
  @rows = map { my $r = $_; +{ map { $_ => $r->{$_} } keys %cols } } @rows if keys %cols;
  return \@rows;
}

sub insert {
  my ($s, $d) = @_;
  my $rows = $s->_rows_arg($d);
  my @b;
  my $sql = $s->grammar->compile_insert($s, $rows, \@b);
  return $s->connection->statement($sql, @b);
}

sub insert_or_ignore {
  my ($s, $d) = @_;
  my $rows = $s->_rows_arg($d);
  my @b;
  my $sql = $s->grammar->compile_insert($s, $rows, \@b, ignore => 1);
  return $s->connection->statement($sql, @b);
}

sub insert_get_id {
  my ($s, $row, $pk) = @_;
  $pk //= $s->model ? $s->model->primary_key : 'id';
  my $r = $s->_rows_arg($row)->[0];
  my @b;
  my $sql = $s->grammar->compile_insert_get_id($s, $r, \@b, $pk);
  return $s->connection->insert_get_id($sql, \@b, $s->from, $pk);
}

sub upsert {
  my ($s, $d, $unique, $update) = @_;
  $unique = [$unique] unless ref $unique;
  my $rows = $s->_rows_arg($d);
  $update //= [grep { my $c = $_; !grep { $_ eq $c } @$unique } sort keys %{$rows->[0]}];
  my @b;
  my $sql = $s->grammar->compile_upsert($s, $rows, \@b, $unique, $update);
  return $s->connection->statement($sql, @b);
}

sub update {
  my ($s, $vals) = @_;
  Carp::croak('Yggdrasil: update() needs a hashref') unless ref $vals eq 'HASH';
  if (my $m = $s->model) {
    $vals = { map { $_ => (ref $vals->{$_} ? $vals->{$_} : $m->cast_for_storage($_, $vals->{$_})) } keys %$vals };
    $vals->{$m->updated_at_column} = $m->now if $m->timestamps && !exists $vals->{$m->updated_at_column};
  }
  my @b;
  my $sql = $s->grammar->compile_update($s, $vals, \@b);
  return $s->connection->statement($sql, @b);
}

sub increment { my ($s, $c, $n, $x) = @_; $s->_incr('+', $c, $n, $x) }
sub decrement { my ($s, $c, $n, $x) = @_; $s->_incr('-', $c, $n, $x) }
sub _incr {
  my ($s, $op, $col, $n, $extra) = @_;
  $n //= 1;
  Carp::croak('Yggdrasil: increment amount must be numeric') unless looks_like_number($n);
  my $w = $s->grammar->wrap($col);
  return $s->update({ %{$extra // {}}, $col => \"$w $op $n" });
}

sub force_delete {
  my $s = shift;
  my @b;
  my $sql = $s->grammar->compile_delete($s, \@b);
  return $s->connection->statement($sql, @b);
}

sub truncate {
  my $s = shift;
  $s->connection->statement($_) for $s->grammar->compile_truncate($s);
  return 1;
}

# Names that collide with Perl built-ins are installed through the symbol table so
# that calls to the real built-ins inside this package stay unambiguous.
{
  no strict 'refs';
  no warnings 'redefine';
  *{__PACKAGE__ . '::with'}   = \&include;   # Moo exports its own `with`; ours wins on query objects
  *{__PACKAGE__ . '::join'}   = sub { my $s = shift; $s->_join('inner', @_) };
  *{__PACKAGE__ . '::exists'} = sub { my $s = shift; defined $s->clone->select(\'1')->limit(1)->_rows->[0] ? 1 : 0 };
  *{__PACKAGE__ . '::each'}   = sub { my ($s, $cb, $size) = @_; $s->chunk($size || 500, sub { $cb->($_) for @{$_[0]}; 1 }) };
  *{__PACKAGE__ . '::delete'} = sub {
    my ($s, $id) = @_;
    $s = $s->clone->where($s->_pk_col, $id) if defined $id;
    my $m = $s->model;
    return $s->update({ $m->deleted_at_column => $m->now }) if $m && $m->soft_deletes;
    return $s->force_delete;
  };
}

# Model scopes: $model->scope_foo($query, @args) becomes $query->foo(@args)
sub AUTOLOAD {
  my $s = shift;
  (my $n = $AUTOLOAD) =~ s/.*:://;
  return if $n eq 'DESTROY';
  my $m = ref $s ? $s->model : undef;
  if ($m && (my $scope = $m->can("scope_$n"))) {
    my $r = $scope->($m, $s, @_);
    return blessed $r && $r->isa('Yggdrasil::Query') ? $r : $s;
  }
  Carp::croak(qq{Can't locate object method "$n" via package "} . (ref $s || $s) . '"');
}

1;
