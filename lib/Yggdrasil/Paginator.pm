package Yggdrasil::Paginator;
use Moo;

has items        => (is => 'ro', required => 1);
has total        => (is => 'ro', required => 1);
has per_page     => (is => 'ro', required => 1);
has current_page => (is => 'ro', required => 1);

sub last_page {
  my $s = shift;
  my $l = int(($s->total + $s->per_page - 1) / $s->per_page);
  return $l < 1 ? 1 : $l;
}
sub from { my $s = shift; $s->total ? ($s->current_page - 1) * $s->per_page + 1 : undef }
sub to   { my $s = shift; $s->total ? $s->from + @{$s->items} - 1 : undef }
sub has_more_pages { $_[0]->current_page < $_[0]->last_page ? 1 : 0 }

sub TO_JSON {
  my $s = shift;
  return {
    data => [@{$s->items}], total => $s->total, per_page => $s->per_page,
    current_page => $s->current_page, last_page => $s->last_page,
    from => $s->from, to => $s->to,
  };
}

1;
