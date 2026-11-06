use Test::More; BEGIN { eval { require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite is required' }
use strict; use warnings; use Yggdrasil;
{ package T::Model::Author; use Moo; extends 'Yggdrasil::Model'; sub fillable {[qw(name)]} sub books { $_[0]->has_many('Book') } sub strict_attributes {1}
  package T::Model::Book; use Moo; extends 'Yggdrasil::Model'; sub fillable {[qw(title author_id)]} sub author { $_[0]->belongs_to('Author') } }
my $m = Yggdrasil->init(connections=>{default=>{driver=>'sqlite',database=>':memory:'}}, model_namespaces=>['T::Model']);
my $s = $m->schema;
$s->create('authors', sub { $_[0]->id; $_[0]->string('name'); $_[0]->timestamps });
$s->create('books', sub { $_[0]->id; $_[0]->foreign_id('author_id')->constrained; $_[0]->string('title'); $_[0]->timestamps });
my $a = T::Model::Author->new({ name => 'A' }); ok !$a->in_storage; $a->save; ok $a->in_storage, 'new()->save';
my $b = T::Model::Book->create({ title => 'B1', author_id => $a->id }); T::Model::Book->create({ title => 'B2', author_id => $a->id });
is scalar @{ T::Model::Author->query->with('books')->get->[0]->relations->{books} }, 2, 'query->with alias';
my $loaded = T::Model::Author->find($a->id)->load('books'); is scalar @{$loaded->relations->{books}}, 2, 'load()';
my $x = T::Model::Book->find($b->id); my $a2 = T::Model::Author->create({ name => 'A2' });
$x->author->associate($a2); $x->save; is(T::Model::Book->find($b->id)->author_id, $a2->id, 'associate');
my $r = $x->replicate; ok !$r->in_storage && !defined $r->id && $r->title eq 'B1', 'replicate';
my $old = $x->updated_at; $x->touch; ok defined $x->updated_at, 'touch';
my @names; T::Model::Book->order_by('id')->each(sub { push @names, $_->title }); is_deeply \@names, [qw(B1 B2)], 'each';
my $q = $m->table('books')->join('authors', sub { $_[0]->on('books.author_id','=','authors.id')->where('authors.name','A2') })->select('books.title');
is_deeply [map { $_->{title} } @{$q->get}], ['B1'], 'join callback';
is $m->table('books')->when(1, sub { $_[0]->where(title=>'B2') })->when(0, sub { $_[0]->where(title=>'zzz') })->count, 1, 'when';
is $m->table('books')->select(\'count(*) as n')->first->{n}, 2, 'raw select expr';
is $m->table('books')->where_raw('title = ?', 'B2')->value('id'), 2, 'value';
is_deeply $m->table('books')->pluck('title','id'), {1=>'B1',2=>'B2'}, 'pluck with key';
eval { $a->no_such_col }; like $@, qr/Can't locate attribute/, 'strict_attributes';
eval { T::Model::Book->bogus }; like $@, qr/Can't locate object method/, 'unknown class method';
my $grp = $m->table('books')->select('author_id', \'count(*) as n')->group_by('author_id')->get; is scalar @$grp, 2;
is $m->table('books')->group_by('author_id')->count, 2, 'count over group by wraps subquery';
my $one = T::Model::Author->query->where('name','A')->first; is $one->name, 'A';
eval { $m->table('books')->insert({ title=>'x', author_id=>9999 }) }; like $@, qr/FOREIGN KEY/i, 'sqlite FKs enforced';
done_testing;
