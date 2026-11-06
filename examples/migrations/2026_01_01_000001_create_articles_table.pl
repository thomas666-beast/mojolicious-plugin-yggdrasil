use strict;
use warnings;

return {
  up => sub {
    my ($schema, $db) = @_;
    $schema->create('articles', sub {
      my $t = shift;
      $t->id;
      $t->string('title');
      $t->text('body')->nullable;
      $t->boolean('published')->default(0);
      $t->integer('views')->default(0);
      $t->json('meta')->nullable;
      $t->timestamps;
      $t->soft_deletes;
    });
  },
  down => sub {
    my ($schema, $db) = @_;
    $schema->drop_if_exists('articles');
  },
};
