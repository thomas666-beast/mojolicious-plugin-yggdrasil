package Yggdrasil::Relation::HasOneOrMany;
use Moo;
extends 'Yggdrasil::Relation';

has foreign_key => (is => 'ro', required => 1);   # column on the related table
has local_key   => (is => 'ro', required => 1);   # column on the parent

sub parent_value { $_[0]->parent->attributes->{$_[0]->local_key} }

sub add_constraints {
  my ($s, $q) = @_;
  my $v = $s->parent_value;
  defined $v ? $q->where($s->related->table . '.' . $s->foreign_key, $v) : $q->where_raw('0 = 1');
}

sub make {
  my ($s, $attrs) = @_;
  my $m = $s->related->new($attrs // {});
  $m->set_attribute($s->foreign_key, $s->parent_value);
  return $m;
}
sub create { my $m = shift->make(@_); $m->save; $m }
sub save   { my ($s, $m) = @_; $m->set_attribute($s->foreign_key, $s->parent_value); $m->save }

sub _group {
  my ($s, $models) = @_;
  my $keys = $s->_keys($models, $s->local_key);
  my $fk = $s->foreign_key;
  my %by;
  push @{$by{$_->attributes->{$fk}}}, $_ for @{$s->_fetch_in($s->related->table . ".$fk", $keys, $s->{_cb})};
  return \%by;
}

1;
