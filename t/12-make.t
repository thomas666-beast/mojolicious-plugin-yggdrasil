use strict; use warnings; use Test::More;
BEGIN {
  eval { require DBD::SQLite; require Mojolicious; 1 } or plan skip_all => 'DBD::SQLite and Mojolicious are required';
}
use File::Temp qw(tempdir);
package FakePath { sub new { bless {p=>$_[1]}, $_[0] } sub child { FakePath->new(join '/', $_[0]{p}, @_[1..$#_]) } sub to_string { $_[0]{p} } }
package FakeApp { sub new { bless {home=>$_[1]}, $_[0] } sub home { FakePath->new($_[0]{home}) } sub yggdrasil { $main::M } }
package main;
use Yggdrasil; require Mojolicious::Plugin::Yggdrasil::Command::yggdrasil;
my $home = tempdir(CLEANUP=>1);
$main::M = Yggdrasil->init(connections=>{default=>{driver=>'sqlite',database=>':memory:'}}, migration_paths=>{default=>["$home/migrations"]}, model_namespaces=>['Blog::Model']);
my $app = FakeApp->new($home);   # keep a reference: Mojolicious::Command holds `app` weakly
my $cmd = Mojolicious::Plugin::Yggdrasil::Command::yggdrasil->new(app => $app);
sub run { my $o=''; open my $h,'>',\$o; local *STDOUT=$h; $cmd->run(@_); $o }
my $out = run('make:model','Post','-m','-f','title:string,body:text?,price:decimal(8,2)=0,user_id:foreign,slug:string!,note:string?=hi');
my $model = do { local (@ARGV,$/)="$home/lib/Blog/Model/Post.pm"; <> };
like $model, qr/package Blog::Model::Post;/; like $model, qr/sub fillable \{ \[qw\(title body price user_id slug note\)\] \}/, 'fillable from fields';
my ($mf) = glob "$home/migrations/*create_posts_table.pl"; ok $mf, 'migration created';
my $mig = do { local (@ARGV,$/)=$mf; <> };
like $mig, qr/\$t->decimal\('price', 8, 2\)->default\(0\);/; like $mig, qr/\$t->foreign_id\('user_id'\)->constrained;/;
like $mig, qr/\$t->string\('slug'\)->unique;/; like $mig, qr/\$t->string\('note'\)->nullable->default\('hi'\);/;
# the generated migration must actually run (users table needed for the FK)
$main::M->schema->create('users', sub { $_[0]->id });
my $r = $main::M->migrator->run; is scalar @$r, 1, 'generated migration runs';
ok $main::M->schema->has_column('posts','slug'), 'columns created';
ok !eval { Yggdrasil::Migrator->parse_fields('x:bogus'); 1 } && $@ =~ /unknown field type/, 'bad type rejected';
ok !eval { $main::M->migrator->parse_fields('nonsense'); 1 }, 'bad spec rejected';
done_testing;
