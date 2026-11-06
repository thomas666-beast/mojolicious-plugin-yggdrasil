package Yggdrasil::Model;
use Moo;
use Carp ();
use JSON::PP ();
use Scalar::Util qw(blessed);
use Yggdrasil;
use Yggdrasil::Query;
use Yggdrasil::Util qw(class_basename snake_case pluralize uniq now_string);
use Yggdrasil::Exception;
use Yggdrasil::Relation::HasOne;
use Yggdrasil::Relation::HasMany;
use Yggdrasil::Relation::BelongsTo;
use Yggdrasil::Relation::BelongsToMany;

our $AUTOLOAD;
my $JSON = JSON::PP->new->canonical->allow_nonref;

# Persisted columns live in `attributes`; everything declared with Moo's `has`
# in a subclass is ordinary, non-persisted state.
has attributes => (is => 'rw', default => sub { +{} });
has original   => (is => 'rw', default => sub { +{} });
has relations  => (is => 'rw', default => sub { +{} });
has in_storage => (is => 'rw', default => sub { 0 });
has pivot      => (is => 'rw');
has using      => (is => 'rw');          # per-instance connection name

# User->new({ name => 'x' }) mass-assigns (respecting fillable/guarded);
# User->new(attributes => {...}, ...) is the plain Moo constructor.
around BUILDARGS => sub {
  my ($orig, $class, @args) = @_;
  return { _fill => $args[0] } if @args == 1 && ref $args[0] eq 'HASH';
  return $class->$orig(@args);
};

sub BUILD {
  my ($s, $args) = @_;
  $s->fill($args->{_fill}) if $args->{_fill};
}

sub DESTROY { }

# ---- class level configuration (override in subclasses) ----------------------------------

sub table              { pluralize(snake_case(class_basename(ref($_[0]) || $_[0]))) }
sub primary_key        { 'id' }
sub incrementing       { 1 }
sub timestamps         { 1 }
sub created_at_column  { 'created_at' }
sub updated_at_column  { 'updated_at' }
sub deleted_at_column  { 'deleted_at' }
sub soft_deletes       { 0 }
sub connection_name    { undef }
sub fillable           { [] }
sub guarded            { [$_[0]->primary_key] }
sub hidden             { [] }
sub appends            { [] }
sub casts              { +{} }
sub per_page           { 15 }
sub strict_attributes  { 0 }
sub now                { now_string() }

# ---- hooks (override, or wrap with Moo's before/after/around; die to abort) ------------

sub saving   { 1 }  sub saved    { 1 }
sub creating { 1 }  sub created  { 1 }
sub updating { 1 }  sub updated  { 1 }
sub deleting { 1 }  sub deleted  { 1 }

# ---- connection & query entry points ------------------------------------------------------

sub manager { Yggdrasil->instance // Carp::croak('Yggdrasil is not initialised (register the plugin or call Yggdrasil->init)') }

sub connection {
  my ($c, $name) = @_;
  $name //= ref $c ? ($c->using // $c->connection_name) : $c->connection_name;
  return manager()->connection($name);
}

sub query {
  my ($class, %o) = @_;
  $class = ref $class || $class;
  my $conn = $o{using} ? manager()->connection($o{using}) : $class->connection;
  my $q = Yggdrasil::Query->new(connection => $conn, model => $class, from => $class->table);
  $q->where_null($class->table . '.' . $class->deleted_at_column)
    if $class->soft_deletes && !$o{with_trashed};
  return $q;
}

sub on  { my ($class, $name) = @_; $class->query(using => $name) }
sub all { $_[0]->query->get }

sub _hydrate {
  my ($class, $row, $conn) = @_;
  return $class->new(attributes => {%$row}, original => {%$row}, in_storage => 1, using => $conn);
}

# ---- static helpers --------------------------------------------------------------------------

sub make   { my ($class, $attrs) = @_; $class->new($attrs // {}) }
sub create { my ($class, $attrs) = @_; my $m = $class->new($attrs // {}); $m->save; $m }

sub first_or_new {
  my ($class, $search, $extra) = @_;
  return $class->query->where($search)->first // $class->new({%$search, %{$extra // {}}});
}
sub first_or_create {
  my ($class, $search, $extra) = @_;
  return $class->query->where($search)->first // $class->create({%$search, %{$extra // {}}});
}
sub update_or_create {
  my ($class, $search, $values) = @_;
  my $m = $class->query->where($search)->first;
  return $m ? $m->update($values) : $class->create({%$search, %{$values // {}}});
}
sub destroy {
  my ($class, @ids) = @_;
  @ids = map { ref $_ eq 'ARRAY' ? @$_ : $_ } @ids;
  my $n = 0;
  for my $id (@ids) { my $m = $class->find($id) or next; $m->delete; $n++ }
  return $n;
}

# ---- attributes ----------------------------------------------------------------------------------

sub cast_for_storage {
  my ($c, $k, $v) = @_;
  my $t = $c->casts->{$k} // return $v;
  return $v unless defined $v;
  return (ref $v ? $JSON->encode($v) : $v) if $t =~ /^(?:json|array|hash|object)$/;
  return ($v ? 1 : 0)                      if $t =~ /^bool(?:ean)?$/;
  return int $v                            if $t =~ /^int(?:eger)?$/;
  return $v;
}

sub _cast_from_storage {
  my ($s, $k, $v) = @_;
  my $t = $s->casts->{$k} // return $v;
  return $v unless defined $v;
  return (ref $v ? $v : $JSON->decode($v)) if $t =~ /^(?:json|array|hash|object)$/;
  return ($v ? JSON::PP::true() : JSON::PP::false()) if $t =~ /^bool(?:ean)?$/;
  return 0 + $v if $t =~ /^(?:int(?:eger)?|float|real|double)$/;
  return $v;
}

sub get_attribute {
  my ($s, $k) = @_;
  my $v = $s->_cast_from_storage($k, $s->attributes->{$k});
  if (my $m = $s->can("get_${k}_attribute")) { return $s->$m($v) }
  return $v;
}

sub set_attribute {
  my ($s, $k, $v) = @_;
  if (my $m = $s->can("set_${k}_attribute")) { $v = $s->$m($v) }
  $s->attributes->{$k} = $s->cast_for_storage($k, $v);
  return $s;
}

sub is_fillable {
  my ($s, $k) = @_;
  my $f = $s->fillable;
  return scalar(grep { $_ eq $k } @$f) ? 1 : 0 if @$f;
  return grep({ $_ eq $k || $_ eq '*' } @{$s->guarded}) ? 0 : 1;
}

sub fill {
  my ($s, $a) = @_;
  for my $k (sort keys %{$a // {}}) { $s->set_attribute($k, $a->{$k}) if $s->is_fillable($k) }
  return $s;
}

sub force_fill {
  my ($s, $a) = @_;
  $s->set_attribute($_, $a->{$_}) for sort keys %{$a // {}};
  return $s;
}

sub get_key { $_[0]->attributes->{$_[0]->primary_key} }

sub _differs {
  my ($a, $b) = @_;
  return 0 if !defined $a && !defined $b;
  return 1 if !defined $a || !defined $b;
  return $a ne $b ? 1 : 0;
}

sub get_dirty {
  my $s = shift;
  my ($a, $o) = ($s->attributes, $s->original);
  return +{ map { $_ => $a->{$_} } grep { !exists $o->{$_} || _differs($a->{$_}, $o->{$_}) } keys %$a };
}

sub is_dirty {
  my ($s, @keys) = @_;
  my $d = $s->get_dirty;
  return @keys ? (grep({ exists $d->{$_} } @keys) ? 1 : 0) : (%$d ? 1 : 0);
}

sub get_original { my ($s, $k) = @_; defined $k ? $s->original->{$k} : {%{$s->original}} }
sub sync_original { $_[0]->original({%{$_[0]->attributes}}); $_[0] }

# ---- persistence -------------------------------------------------------------------------------------

sub _table_query { $_[0]->connection->table($_[0]->table) }

sub save {
  my $s = shift;
  $s->saving;
  $s->in_storage ? $s->_perform_update : $s->_perform_insert;
  $s->sync_original;
  $s->saved;
  return $s;
}

sub _perform_insert {
  my $s = shift;
  $s->creating;
  if ($s->timestamps) {
    my $now = $s->now;
    $s->attributes->{$_} //= $now for $s->created_at_column, $s->updated_at_column;
  }
  my $attrs = {%{$s->attributes}};
  my $pk = $s->primary_key;
  if ($s->incrementing && !defined $attrs->{$pk}) {
    CORE::delete $attrs->{$pk};
    $s->attributes->{$pk} = $s->_table_query->insert_get_id($attrs, $pk);
  }
  else { $s->_table_query->insert($attrs) }
  $s->in_storage(1);
  $s->created;
}

sub _perform_update {
  my $s = shift;
  return unless %{$s->get_dirty};
  $s->updating;
  if ($s->timestamps && !$s->is_dirty($s->updated_at_column)) {
    $s->attributes->{$s->updated_at_column} = $s->now;
  }
  my $dirty = $s->get_dirty;
  my $key = $s->get_key;
  Carp::croak('Yggdrasil: cannot update a model without a primary key value') unless defined $key;
  $s->_table_query->where($s->primary_key, $key)->update($dirty);
  $s->updated;
}

sub update {
  my ($s, $attrs) = @_;
  return $s->fill($attrs)->save;
}

sub touch {
  my $s = shift;
  return $s unless $s->timestamps;
  $s->attributes->{$s->updated_at_column} = $s->now;
  return $s->save;
}

sub increment { my ($s, $c, $n, $x) = @_; $s->_incr(1, $c, $n, $x) }
sub decrement { my ($s, $c, $n, $x) = @_; $s->_incr(-1, $c, $n, $x) }
sub _incr {
  my ($s, $sign, $col, $n, $extra) = @_;
  $n //= 1;
  my $q = $s->_table_query->where($s->primary_key, $s->get_key);
  $sign > 0 ? $q->increment($col, $n, $extra) : $q->decrement($col, $n, $extra);
  $s->attributes->{$col} = ($s->attributes->{$col} // 0) + $sign * $n;
  $s->attributes->{$_} = $extra->{$_} for keys %{$extra // {}};
  $s->original->{$_} = $s->attributes->{$_} for $col, keys %{$extra // {}};
  return $s;
}

sub delete {
  my $s = shift;
  return 0 unless $s->in_storage;
  $s->deleting;
  $s->_do_delete;
  $s->deleted;
  return 1;
}

sub _hard_delete {
  my $s = shift;
  $s->_table_query->where($s->primary_key, $s->get_key)->force_delete;
  $s->in_storage(0);
}
sub _do_delete { $_[0]->_hard_delete }

sub refresh {
  my $s = shift;
  my $row = $s->_table_query->where($s->primary_key, $s->get_key)->first
    or Yggdrasil::Exception->throw(message => 'Cannot refresh: row no longer exists', type => 'model_not_found');
  $s->attributes({%$row});
  $s->original({%$row});
  $s->relations({});
  return $s;
}

sub fresh {
  my $s = shift;
  return (ref $s)->query(with_trashed => 1, using => $s->using)->find($s->get_key);
}

sub replicate {
  my ($s, @except) = @_;
  push @except, $s->primary_key, $s->created_at_column, $s->updated_at_column;
  my %a = %{$s->attributes};
  CORE::delete @a{@except};
  my $m = (ref $s)->new;
  $m->using($s->using);
  return $m->force_fill(\%a);
}

# ---- serialisation ------------------------------------------------------------------------------------------

sub to_hash {
  my $s = shift;
  my %hide = map { $_ => 1 } @{$s->hidden};
  my %h = map { $_ => $s->get_attribute($_) } grep { !$hide{$_} } keys %{$s->attributes};
  $h{$_} = $s->get_attribute($_) for grep { !$hide{$_} } @{$s->appends};
  while (my ($name, $r) = each %{$s->relations}) {
    $h{$name} = !defined $r ? undef
      : blessed $r && $r->isa('Mojo::Collection') ? [map { $_->to_hash } @$r]
      : $r->to_hash;
  }
  $h{pivot} = {%{$s->pivot}} if $s->pivot;
  return \%h;
}
sub TO_JSON { $_[0]->to_hash }

# ---- relations -------------------------------------------------------------------------------------------------

sub _fk_for { snake_case(class_basename(ref($_[0]) || $_[0])) . '_id' }

sub has_one {
  my ($s, $related, $fk, $lk) = @_;
  return Yggdrasil::Relation::HasOne->new(
    parent => $s, related => manager()->model($related),
    foreign_key => $fk // $s->_fk_for, local_key => $lk // $s->primary_key);
}

sub has_many {
  my ($s, $related, $fk, $lk) = @_;
  return Yggdrasil::Relation::HasMany->new(
    parent => $s, related => manager()->model($related),
    foreign_key => $fk // $s->_fk_for, local_key => $lk // $s->primary_key);
}

sub belongs_to {
  my ($s, $related, $fk, $owner) = @_;
  my $class = manager()->model($related);
  return Yggdrasil::Relation::BelongsTo->new(
    parent => $s, related => $class,
    foreign_key => $fk // $class->_fk_for, owner_key => $owner // $class->primary_key);
}

sub belongs_to_many {
  my ($s, $related, $pivot, $fpk, $rpk, $pk, $rk) = @_;
  my $class = manager()->model($related);
  return Yggdrasil::Relation::BelongsToMany->new(
    parent => $s, related => $class,
    pivot_table       => $pivot // CORE::join('_', sort { $a cmp $b } map { snake_case(class_basename($_)) } (ref $s, $class)),
    foreign_pivot_key => $fpk // $s->_fk_for,
    related_pivot_key => $rpk // $class->_fk_for,
    parent_key        => $pk // $s->primary_key,
    related_key       => $rk // $class->primary_key);
}

sub set_relation    { $_[0]->relations->{$_[1]} = $_[2]; $_[0] }
sub relation_loaded { exists $_[0]->relations->{$_[1]} ? 1 : 0 }

# $user->related('posts'): loaded value (lazy-loads once)
sub related {
  my ($s, $name) = @_;
  return $s->relations->{$name} if exists $s->relations->{$name};
  my $rel = $s->$name;
  Carp::croak(qq{"$name" is not a relation on } . ref $s) unless blessed $rel && $rel->isa('Yggdrasil::Relation');
  return $s->relations->{$name} = $rel->results;
}

sub load {
  my ($s, @names) = @_;
  (ref $s)->eager_load_relations([$s], [map { [$_, undef] } @names]);
  return $s;
}

sub eager_load_relations {
  my ($class, $models, $specs) = @_;
  return unless @$models;
  my %done;
  for my $spec (@$specs) {
    my ($name, $cb) = @$spec;
    my ($first, $rest) = split /\./, $name, 2;
    unless ($done{$first}++) {
      my $rel = $models->[0]->$first;
      Carp::croak(qq{"$first" is not a relation on } . ref $models->[0]) unless blessed $rel && $rel->isa('Yggdrasil::Relation');
      $rel->eager_load($models, $first, defined $rest ? undef : $cb);
    }
    next unless defined $rest;
    my @related = map {
      my $r = $_->relations->{$first};
      !defined $r ? () : blessed $r && $r->isa('Mojo::Collection') ? @$r : ($r);
    } @$models;
    $related[0]->eager_load_relations(\@related, [[$rest, $cb]]) if @related;
  }
  return;
}

# ---- query forwarding & attribute access -------------------------------------------------------------------------

for my $m (qw(
  where or_where where_in where_not_in where_null where_not_null where_between where_raw where_column
  where_exists select group_by having order_by order_by_desc latest oldest limit offset take skip include
  join left_join first find find_or_fail first_or_fail count sum avg min max pluck value paginate chunk
  lock_for_update distinct when tap truncate insert upsert insert_or_ignore
)) {
  no strict 'refs';
  *{__PACKAGE__ . "::$m"} = sub {
    my $s = shift;
    if (ref $s) {
      return $s->get_attribute($m) if !@_ && exists $s->attributes->{$m};
      Carp::croak(qq{"$m" is a static query method; call it on the class (use get_attribute for a column called "$m")});
    }
    return $s->query->$m(@_);
  };
}

sub AUTOLOAD {
  my $s = shift;
  (my $n = $AUTOLOAD) =~ s/.*:://;
  return if $n eq 'DESTROY';
  unless (ref $s) {
    return $s->query->$n(@_) if $s->can("scope_$n");
    Carp::croak(qq{Can't locate object method "$n" via package "$s"});
  }
  if (@_) { $s->set_attribute($n, $_[0]); return $s }
  Carp::croak(qq{Can't locate attribute "$n" on } . ref $s)
    if $s->strict_attributes && !exists $s->attributes->{$n} && !$s->can("get_${n}_attribute");
  return $s->get_attribute($n);
}

1;
