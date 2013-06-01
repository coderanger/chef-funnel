# Here Be Dragons

Okay, consider yourself warned. The ``funnel`` cookbook provides a way to
write Chef recipes in Javascript or Python. Just put a ``.js`` or ``.py`` file in your recipes folder
just like you would with a normal Ruby recipe.

## Example Javscript recipe

The resource syntax is a pretty direct mapping from Ruby:

```javascript
package('ntp');

file('/tmp/something', {
  owner: 'root',
  mode: '600',
  content: 'secret'
});

file('/tmp/something', {
  action: 'delete'
});

template('/tmp/another', {
  source: 'test.erb',
  variables: {
    name: node.name(),
    server: node.fqdn
  }
});
```

## Example Python receipe

As above, pretty simple mapping, except all methods live under the ``chef`` module.
The node object is not yet exposed to Python:

```python
import chef

chef.package('ntp')

chef.file('/tmp/something',
    owner='root',
    mode='600',
    content='secret')

# You can also import * if you prefer
from chef import file, template

file('/tmp/something', action='delete')

template('/tmp/another',
    source='test.erb',
    variables={
      'name': 'localhost',
    })
```

## Why?

Because I can. Using this in production will probably result in your servers
catching fire.
