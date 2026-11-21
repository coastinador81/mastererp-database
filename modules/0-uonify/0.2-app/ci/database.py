from pathlib import Path
import hashlib
import psycopg
from psycopg.rows import dict_row


class Database:
    def __init__(self, config):
        self.config = config

    def connect(self):
        return psycopg.connect(**self.config, row_factory=dict_row, connect_timeout=5)

    def migrate(self):
        with self.connect() as connection:
            connection.execute('SELECT pg_advisory_xact_lock(71072026)')
            connection.execute('CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY, checksum text NOT NULL)')
            for path in sorted((Path(__file__).parent.parent / 'migrations').glob('*.sql')):
                sql = path.read_text()
                checksum = hashlib.sha256(sql.encode()).hexdigest()
                previous = connection.execute('SELECT checksum FROM schema_migrations WHERE name=%s', (path.name,)).fetchone()
                if previous:
                    if previous['checksum'] != checksum:
                        raise RuntimeError('Una migración aplicada ha cambiado')
                    continue
                connection.execute(sql)
                connection.execute('INSERT INTO schema_migrations VALUES (%s,%s)', (path.name, checksum))
