-- MySQL 8 extras, applied after mysql.sql on the MySQL 8.4 test server.
--
-- MySQL 8 servers announce caching_sha2_password at login; root uses it. This account
-- stays on mysql_native_password (the server runs with --mysql-native-password=ON), so
-- the login has to follow the server's request to switch methods (MySQL8Tests.authSwitch).
CREATE USER IF NOT EXISTS 'sbnative'@'%' IDENTIFIED WITH mysql_native_password BY 'sbnative123';
GRANT SELECT ON *.* TO 'sbnative'@'%';
