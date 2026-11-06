package Mimir::Relation::HasMany;
use Moo;
use Mojo::Collection;
extends 'Mimir::Relation::HasOneOrMany';

sub results { $_[0]->get }

sub eager_load {
  my ($s, $models, $name, $cb) = @_;
  local $s->{_cb} = $cb;
  my $by = $s->_group($models);
  my $lk = $s->local_key;
  $_->set_relation($name, Mojo::Collection->new(@{$by->{$_->attributes->{$lk} // ''} // []})) for @$models;
}

1;
