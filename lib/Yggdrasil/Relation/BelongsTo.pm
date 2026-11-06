package Yggdrasil::Relation::BelongsTo;
use Moo;
extends 'Yggdrasil::Relation';

has foreign_key => (is => 'ro', required => 1);   # column on the parent
has owner_key   => (is => 'ro', required => 1);   # column on the related table

sub add_constraints {
  my ($s, $q) = @_;
  my $v = $s->parent->attributes->{$s->foreign_key};
  defined $v ? $q->where($s->related->table . '.' . $s->owner_key, $v) : $q->where_raw('0 = 1');
}

sub results { $_[0]->first }

sub associate {
  my ($s, $model) = @_;
  $s->parent->set_attribute($s->foreign_key, $model ? $model->attributes->{$s->owner_key} : undef);
  return $s->parent;
}
sub dissociate { $_[0]->associate(undef) }

sub eager_load {
  my ($s, $models, $name, $cb) = @_;
  my $keys = $s->_keys($models, $s->foreign_key);
  my $ok = $s->owner_key;
  my %by = map { $_->attributes->{$ok} => $_ } @{$s->_fetch_in($s->related->table . ".$ok", $keys, $cb)};
  $_->set_relation($name, $by{$_->attributes->{$s->foreign_key} // ''}) for @$models;
}

1;
