package MyApp::Model::Article;
use Moo;
extends 'Mimir::Model';
with 'Mimir::Role::SoftDeletes';

sub fillable { [qw(title body published meta)] }
sub casts    { { published => 'bool', meta => 'json', views => 'int' } }

# local scopes:  Article->published->latest->get
sub scope_published { my ($class, $q) = @_; $q->where(published => 1) }

# accessor / mutator:  $article->title  /  $article->title('x')
sub get_title_attribute { ucfirst $_[1] }

1;
