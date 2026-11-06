package Yggdrasil::Schema::ForeignKey;
use Moo;
use Carp ();

has columns    => (is => 'ro', required => 1);
has _table     => (is => 'rw');
has _refs      => (is => 'rw');
has _on_delete => (is => 'rw');
has _on_update => (is => 'rw');
has fk_name    => (is => 'rw');

sub _action {
  my $a = lc shift;
  Carp::croak("Yggdrasil: invalid foreign key action '$a'") unless $a =~ /^(?:cascade|restrict|set null|set default|no action)$/;
  return $a;
}

sub references { my $s = shift; $s->_refs([ref $_[0] ? @{$_[0]} : @_]); $s }
sub on         { my ($s, $t) = @_; $s->_table($t); $s }
sub on_delete  { my ($s, $a) = @_; $s->_on_delete(_action($a)); $s }
sub on_update  { my ($s, $a) = @_; $s->_on_update(_action($a)); $s }
sub cascade_on_delete  { $_[0]->on_delete('cascade') }
sub cascade_on_update  { $_[0]->on_update('cascade') }
sub null_on_delete     { $_[0]->on_delete('set null') }
sub restrict_on_delete { $_[0]->on_delete('restrict') }
sub name        { my ($s, $n) = @_; $s->fk_name($n); $s }

sub table         { $_[0]->_table }
sub ref_columns   { $_[0]->_refs // ['id'] }
sub delete_action { $_[0]->_on_delete }
sub update_action { $_[0]->_on_update }

package Yggdrasil::Schema::Column;
use Moo;
use Yggdrasil::Util qw(pluralize);

has name  => (is => 'ro', required => 1);
has type  => (is => 'ro', required => 1);
has attrs => (is => 'ro', default => sub { +{} });

sub nullable       { my ($s, $v) = @_; $s->attrs->{nullable} = (defined $v ? ($v ? 1 : 0) : 1); $s }
sub default        { my ($s, $v) = @_; @{$s->attrs}{qw(default has_default)} = ($v, 1); $s }
sub use_current    { $_[0]->default(\'CURRENT_TIMESTAMP') }
sub unsigned       { $_[0]->attrs->{unsigned} = 1; $_[0] }
sub primary        { $_[0]->attrs->{primary} = 1; $_[0] }
sub unique         { $_[0]->attrs->{unique} = 1; $_[0] }
sub comment        { $_[0]->attrs->{comment} = $_[1]; $_[0] }

sub _fk {
  my $s = shift;
  return $s->attrs->{fk} //= Yggdrasil::Schema::ForeignKey->new(columns => [$s->name]);
}

sub constrained {
  my ($s, $table, $col) = @_;
  unless (defined $table) { ($table = $s->name) =~ s/_id$//; $table = pluralize($table) }
  $s->_fk->on($table)->references($col // 'id');
  return $s;
}
sub references         { my $s = shift; $s->_fk->references(@_); $s }
sub on                 { my $s = shift; $s->_fk->on(@_); $s }
sub on_delete          { my $s = shift; $s->_fk->on_delete(@_); $s }
sub on_update          { my $s = shift; $s->_fk->on_update(@_); $s }
sub cascade_on_delete  { $_[0]->on_delete('cascade') }
sub null_on_delete     { $_[0]->on_delete('set null') }
sub restrict_on_delete { $_[0]->on_delete('restrict') }

{
  no strict 'refs';
  no warnings 'redefine';
  *{__PACKAGE__ . '::after'} = sub { $_[0]->attrs->{after} = $_[1]; $_[0] };   # overrides Moo's `after`
  *{__PACKAGE__ . '::index'} = sub { $_[0]->attrs->{index} = 1; $_[0] };
}

1;
