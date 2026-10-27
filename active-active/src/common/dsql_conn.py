"""Aurora DSQL connections authenticated with short-lived IAM tokens.

There is no password anywhere in the active-active stack: every connection
presents a SigV4-signed token generated from the function's own IAM role, and
the role is mapped to a narrowly-privileged database role (AWS IAM GRANT).

Copied into each function package by scripts/build.sh.
"""

import ssl
import time

import boto3
import pg8000.native

PORT = 5432
DATABASE = "postgres"  # DSQL has exactly one database per cluster
# DSQL closes connections after 1 h; recycle well before that, and before the
# 15-minute token used to open it would matter for a reconnect.
MAX_CONNECTION_AGE = 600

_ssl = ssl.create_default_context()


class DsqlConnection:
    def __init__(self, endpoint, region, user, timeout=3):
        self.endpoint = endpoint
        self.region = region
        self.user = user
        self.timeout = timeout
        self._dsql = boto3.client("dsql", region_name=region)
        self._conn = None
        self._opened = 0.0

    def _token(self):
        if self.user == "admin":
            return self._dsql.generate_db_connect_admin_auth_token(self.endpoint, self.region)
        return self._dsql.generate_db_connect_auth_token(self.endpoint, self.region)

    def _connect(self):
        self.close()
        self._conn = pg8000.native.Connection(
            user=self.user,
            password=self._token(),
            host=self.endpoint,
            port=PORT,
            database=DATABASE,
            ssl_context=_ssl,
            timeout=self.timeout,
        )
        self._opened = time.monotonic()

    def close(self):
        if self._conn is not None:
            try:
                self._conn.close()
            except Exception:
                pass
            self._conn = None

    def run(self, sql, retry=True, **params):
        """Run one statement in its own (auto-committed) transaction.

        Retries once on a fresh connection: a pooled connection that went
        stale between Lambda invocations should not count as an outage.
        Only call with retry=True for idempotent statements.
        """
        if self._conn is None or time.monotonic() - self._opened > MAX_CONNECTION_AGE:
            self._connect()
        try:
            return self._conn.run(sql, **params)
        except Exception:
            self.close()
            if not retry:
                raise
            self._connect()
            return self._conn.run(sql, **params)
