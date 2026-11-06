package Mimir::Role::SoftDeletes;
use Moo::Role;

sub soft_deletes { 1 }

sub with_trashed { $_[0]->query(with_trashed => 1) }
sub only_trashed { $_[0]->query(with_trashed => 1)->where_not_null($_[0]->table . '.' . $_[0]->deleted_at_column) }

sub trashed { defined $_[0]->attributes->{$_[0]->deleted_at_column} ? 1 : 0 }

sub restoring { 1 }
sub restored  { 1 }

sub _do_delete {
  my $s = shift;
  my %v = ($s->deleted_at_column => $s->now);
  $v{$s->updated_at_column} = $v{$s->deleted_at_column} if $s->timestamps;
  $s->_table_query->where($s->primary_key, $s->get_key)->update(\%v);
  @{$s->attributes}{keys %v} = values %v;
  @{$s->original}{keys %v}   = values %v;
}

sub force_delete {
  my $s = shift;
  return 0 unless $s->in_storage;
  $s->deleting;
  $s->_hard_delete;
  $s->deleted;
  return 1;
}

sub restore {
  my $s = shift;
  $s->restoring;
  $s->attributes->{$s->deleted_at_column} = undef;
  $s->save;
  $s->restored;
  return $s;
}

1;
