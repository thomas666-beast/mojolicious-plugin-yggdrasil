package Mimir::Relation::BelongsToMany;
use Moo;
use Carp ();
use Scalar::Util qw(blessed);
use Mojo::Collection;
extends 'Mimir::Relation';

has pivot_table       => (is => 'ro', required => 1);
has foreign_pivot_key => (is => 'ro', required => 1);   # pivot column pointing at the parent
has related_pivot_key => (is => 'ro', required => 1);   # pivot column pointing at the related model
has parent_key        => (is => 'ro', required => 1);
has related_key       => (is => 'ro', required => 1);
has pivot_columns     => (is => 'ro', default => sub { [] });

my $PFX = 'mimir_pivot_';

sub with_pivot { my $s = shift; push @{$s->pivot_columns}, @_; $s }

sub _pivot_selects {
  my $s = shift;
  my $p = $s->pivot_table;
  return map { "$p.$_ as $PFX$_" } ($s->foreign_pivot_key, $s->related_pivot_key, @{$s->pivot_columns});
}

sub _join_pivot {
  my ($s, $q) = @_;
  my $p = $s->pivot_table;
  $q->select($s->related->table . '.*', $s->_pivot_selects)
    ->join($p, $s->related->table . '.' . $s->related_key, '=', "$p." . $s->related_pivot_key);
}

sub _build_query {
  my $s = shift;
  my $q = $s->related->query;
  $s->_join_pivot($q);
  my $v = $s->parent->attributes->{$s->parent_key};
  defined $v ? $q->where($s->pivot_table . '.' . $s->foreign_pivot_key, $v) : $q->where_raw('0 = 1');
  return $q;
}

sub _extract_pivot {
  my ($s, $m) = @_;
  my %p;
  for my $k (grep { index($_, $PFX) == 0 } keys %{$m->attributes}) {
    $p{substr $k, length $PFX} = CORE::delete $m->attributes->{$k};
    CORE::delete $m->original->{$k};
  }
  $m->pivot(\%p);
  return \%p;
}

sub _post { my ($s, $models) = @_; $s->_extract_pivot($_) for @$models }

sub results { $_[0]->get }

sub eager_load {
  my ($s, $models, $name, $cb) = @_;
  my $keys = $s->_keys($models, $s->parent_key);
  my $fpk = $s->pivot_table . '.' . $s->foreign_pivot_key;
  my $rows = $s->_fetch_in($fpk, $keys, $cb, sub { $s->_join_pivot($_[0]) });
  my %by;
  for my $m (@$rows) {
    my $p = $s->_extract_pivot($m);
    push @{$by{$p->{$s->foreign_pivot_key}}}, $m;
  }
  $_->set_relation($name, Mojo::Collection->new(@{$by{$_->attributes->{$s->parent_key} // ''} // []})) for @$models;
}

# ---- pivot management -------------------------------------------------------------------

sub _pq { $_[0]->parent->connection->table($_[0]->pivot_table) }

sub _normalize_ids {
  my ($s, $ids) = @_;
  my %ids;                                     # id => extra pivot attributes
  if (ref $ids eq 'HASH') { %ids = map { $_ => ($ids->{$_} // {}) } keys %$ids }
  else {
    for my $i (ref $ids eq 'ARRAY' ? @$ids : ($ids)) {
      $ids{blessed $i ? $i->attributes->{$s->related_key} : $i} = {};
    }
  }
  return \%ids;
}

sub attach {
  my ($s, $ids, $attrs) = @_;
  my $n = $s->_normalize_ids($ids);
  my $pk = $s->parent->attributes->{$s->parent_key};
  Carp::croak('Mimir: cannot attach on an unsaved model') unless defined $pk;
  my @rows = map { +{ %{$attrs // {}}, %{$n->{$_}}, $s->foreign_pivot_key => $pk, $s->related_pivot_key => $_ } } sort keys %$n;
  $s->_pq->insert(\@rows) if @rows;
  return scalar @rows;
}

sub detach {
  my ($s, $ids) = @_;
  my $q = $s->_pq->where($s->foreign_pivot_key, $s->parent->attributes->{$s->parent_key});
  $q->where_in($s->related_pivot_key, [sort keys %{$s->_normalize_ids($ids)}]) if defined $ids;
  return $q->delete;
}

sub sync {
  my ($s, $ids) = @_;
  my $want = $s->_normalize_ids($ids);
  my $current = $s->_pq->where($s->foreign_pivot_key, $s->parent->attributes->{$s->parent_key})->pluck($s->related_pivot_key);
  my %have = map { $_ => 1 } @$current;
  my @detach = grep { !exists $want->{$_} } sort keys %have;
  my @attach = grep { !$have{$_} } sort keys %$want;
  $s->detach(\@detach) if @detach;
  $s->attach({ map { $_ => $want->{$_} } @attach }) if @attach;
  return { attached => \@attach, detached => \@detach };
}

1;
