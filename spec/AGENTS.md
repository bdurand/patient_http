## Testing

Avoid using double and instance_double in favor of using real instances of classes when possible.

Avoid building stub classes to mock behavior of classes defined in the project for use in tests. Use the real classes instead.

Running the full test suite requires running the included docker-compose.yml file to start up a valkey and s3mock server.
