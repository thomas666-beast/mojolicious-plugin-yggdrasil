package Mimir::Schema::Blueprint;
use Moo;
use Carp ();
use Mimir::Util qw(index_name);
use Mimir::Schema::Column;

has table    => (is => 'ro', required => 1);
has create   => (is => 'ro', default => sub { 0 });
has columns  => (is => 'ro', default => sub { [] });
has commands => (is => 'ro', default => sub { [] });

sub _col {
  my ($s, $type, $name, %a) = @_;
  Carp::croak('Mimir: column name required') unless defined $name;
  my $c = Mimir::Schema::Column->new(name => $name, type => $type, attrs => {%a});
  push @{$s->columns}, $c;
  return $c;
}

sub big_increments { $_[0]->_col('big_increments', $_[1], auto_increment => 1, primary => 1, unsigned => 1) }
sub increments     { $_[0]->_col('increments',     $_[1], auto_increment => 1, primary => 1, unsigned => 1) }
sub id             { $_[0]->big_increments($_[1] // 'id') }

sub string         { $_[0]->_col('string', $_[1], length => $_[2] // 255) }
sub char           { $_[0]->_col('char',   $_[1], length => $_[2] // 255) }
sub text           { $_[0]->_col('text', $_[1]) }
sub medium_text    { $_[0]->_col('medium_text', $_[1]) }
sub long_text      { $_[0]->_col('long_text', $_[1]) }
sub integer        { $_[0]->_col('integer', $_[1]) }
sub big_integer    { $_[0]->_col('big_integer', $_[1]) }
sub small_integer  { $_[0]->_col('small_integer', $_[1]) }
sub tiny_integer   { $_[0]->_col('tiny_integer', $_[1]) }
sub unsigned_integer     { $_[0]->integer($_[1])->unsigned }
sub unsigned_big_integer { $_[0]->big_integer($_[1])->unsigned }
sub boolean        { $_[0]->_col('boolean', $_[1]) }
sub float          { $_[0]->_col('float', $_[1]) }
sub double         { $_[0]->_col('double', $_[1]) }
sub decimal        { $_[0]->_col('decimal', $_[1], precision => $_[2] // 8, scale => $_[3] // 2) }
sub date           { $_[0]->_col('date', $_[1]) }
sub datetime       { $_[0]->_col('datetime', $_[1]) }
sub timestamp      { $_[0]->_col('timestamp', $_[1]) }
sub json           { $_[0]->_col('json', $_[1]) }
sub uuid           { $_[0]->_col('uuid', $_[1]) }
sub binary         { $_[0]->_col('binary', $_[1]) }
sub enum           { $_[0]->_col('enum', $_[1], allowed => $_[2]) }
sub foreign_id     { $_[0]->big_integer($_[1])->unsigned }
sub remember_token { $_[0]->string('remember_token', 100)->nullable }

sub timestamps {
  my $s = shift;
  $s->timestamp('created_at')->nullable;
  $s->timestamp('updated_at')->nullable;
  return;
}
sub soft_deletes { $_[0]->timestamp($_[1] // 'deleted_at')->nullable }

sub _cols { my $c = shift; ref $c eq 'ARRAY' ? $c : [$c] }

sub foreign {
  my ($s, $cols, $name) = @_;
  my $fk = Mimir::Schema::ForeignKey->new(columns => _cols($cols), fk_name => $name);
  push @{$s->commands}, { name => 'foreign', fk => $fk };
  return $fk;
}

sub primary { my ($s, $cols) = @_; push @{$s->commands}, { name => 'primary', columns => _cols($cols) }; $s }
sub unique  { my ($s, $cols, $name) = @_; push @{$s->commands}, { name => 'unique', columns => _cols($cols), index => $name }; $s }

sub drop_column {
  my $s = shift;
  push @{$s->commands}, { name => 'drop_column', columns => [map { ref $_ ? @$_ : $_ } @_] };
  $s;
}
sub rename_column  { my ($s, $f, $t) = @_; push @{$s->commands}, { name => 'rename_column', from => $f, to => $t }; $s }
sub drop_timestamps   { $_[0]->drop_column('created_at', 'updated_at') }
sub drop_soft_deletes { $_[0]->drop_column($_[1] // 'deleted_at') }

sub _drop_named {
  my ($s, $cmd, $type, $arg) = @_;
  my $n = ref $arg eq 'ARRAY' ? index_name($s->table, $arg, $type) : $arg;
  push @{$s->commands}, { name => $cmd, index => $n };
  return $s;
}
sub drop_index   { $_[0]->_drop_named('drop_index',   'index',   $_[1]) }
sub drop_unique  { $_[0]->_drop_named('drop_unique',  'unique',  $_[1]) }
sub drop_foreign { $_[0]->_drop_named('drop_foreign', 'foreign', $_[1]) }

{
  no strict 'refs';
  *{__PACKAGE__ . '::index'} = sub {
    my ($s, $cols, $name) = @_;
    push @{$s->commands}, { name => 'index', columns => _cols($cols), index => $name };
    $s;
  };
  *{__PACKAGE__ . '::time'} = sub { $_[0]->_col('time', $_[1]) };
}

1;
