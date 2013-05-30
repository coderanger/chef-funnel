# Here Be Dragons

Okay, consider yourself warned. The ``funnel-js`` cookbook provides a way to
write Chef recipes in Javascript.

## Example recipe

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
    name: 'World'
  }
});
```

## Why?

Because I can. Using this in production will probably result in your servers
catching fire.
