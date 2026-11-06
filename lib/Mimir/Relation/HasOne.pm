package Mimir::Relation::HasOne;
use Moo;
extends 'Mimir::Relation::HasOneOrMany';

sub results { $_[0]->first }

sub eager_load {
  my ($s, $models, $name, $cb) = @_;
  local $s->{_cb} = $cb;
  my $by = $s->_group($models);
  my $lk = $s->local_key;
  $_->set_relation($name, ($by->{$_->attributes->{$lk} // ''} // [])->[0]) for @$models;
}

1;
