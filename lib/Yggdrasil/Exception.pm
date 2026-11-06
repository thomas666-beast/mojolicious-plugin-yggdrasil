package Yggdrasil::Exception;
use Moo;
use overload '""' => sub { $_[0]->to_string }, 'bool' => sub { 1 }, fallback => 1;

has message  => (is => 'ro', required => 1);
has type     => (is => 'ro', default => sub { 'error' });
has sql      => (is => 'ro');
has bindings => (is => 'ro');
has model    => (is => 'ro');

sub throw {
  my $class = shift;
  my %a = @_ == 1 ? (message => $_[0]) : @_;
  die $class->new(%a);
}

sub to_string {
  my $s = shift;
  my $m = $s->message;
  $m =~ s/\s+\z//;
  $m .= ' (SQL: ' . $s->sql . ')' if defined $s->sql;
  return "$m\n";
}

sub is_not_found { $_[0]->type eq 'model_not_found' }

1;
