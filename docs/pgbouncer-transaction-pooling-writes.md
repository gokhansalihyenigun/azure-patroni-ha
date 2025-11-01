# PgBouncer Transaction Pooling ve Yazma İşlemleri

## Neden Zero Data Loss Test'i PgBouncer Bypass Ediyor?

### 1. Transaction Pooling Mode'un Çalışma Şekli

**Transaction Pooling Mode (`pool_mode = transaction`):**
- Her transaction bitince bağlantı pool'a geri döner
- Farklı client'lar aynı backend bağlantısını kullanabilir
- **Önemli:** Transaction arası state korunmaz (örn: session variables, prepared statements)

### 2. Yazma İşlemlerinde Sorunlar

#### A. Prepared Statements Sorunu
PgBouncer transaction pooling'de:
- Prepared statement'lar transaction scope'unda değil, **connection scope'unda** tutulur
- Transaction bittiğinde bağlantı pool'a döner, ama prepared statement başka bir client'a ait olabilir
- **Sonuç:** "prepared statement does not exist" hataları

**pgbench örneği:**
```sql
-- pgbench yazma workload'ı şunları yapar:
PREPARE pgbench_insert_1(int, int, int) AS INSERT INTO pgbench_history...
PREPARE pgbench_update_1(int) AS UPDATE pgbench_branches...

-- Transaction pooling'de, bu prepared statement'lar
-- transaction bitince kaybolabilir veya başka transaction'a ait olabilir
```

#### B. Failover Sırasında Transaction State
Failover sırasında:
1. PgBouncer bir backend bağlantısı üzerinde transaction başlatır
2. Failover olur, backend değişir (eski primary → yeni primary)
3. **Sorun:** PgBouncer henüz failover'ı fark etmemiş olabilir
4. Transaction yeni primary'ye gönderilir ama **transaction ID/state** tutarsız olabilir
5. **Sonuç:** "connection lost", "transaction aborted" hataları

#### C. Multi-Statement Transactions
pgbench'in write workload'ı çoklu statement'lar içerir:
```sql
BEGIN;
UPDATE pgbench_branches SET bbalance = bbalance + 123 WHERE bid = 1;
UPDATE pgbench_tellers SET tbalance = tbalance + 123 WHERE tid = 1;
INSERT INTO pgbench_history (tid, bid, aid, delta, mtime) VALUES (...);
COMMIT;
```

Transaction pooling'de:
- Her statement arası connection değişebilir (teoride olmaması gerekir ama timing'e bağlı)
- Failover sırasında transaction'ın ortasında connection kesilirse, **partial transaction** riski

### 3. Neden SELECT-Only Testler Çalışır?

SELECT-only testler (`pgbench -S`):
- **Read-only:** Transaction içinde state değiştirmez
- **Hazır statement yok:** Basit SELECT'ler, prepared statement gerektirmez
- **Failover toleransı:** Read-only transaction failover'da daha güvenli
- **Sonuç:** Transaction pooling ile uyumlu

### 4. Zero Data Loss Test'i Neden Bypass Ediyor?

**Zero Data Loss Test'in amacı:**
- **RPO=0 (Recovery Point Objective):** Hiç veri kaybı olmaması
- Yazma işlemleri sırasında failover
- Verinin **mutlaka** persistent olması (synchronous replication garantisi)

**PgBouncer bypass nedenleri:**
1. **Guarantee gereksinimi:** Direkt DB bağlantısı ile synchronous replication garantisi daha net
2. **Transaction integrity:** Multi-statement transaction'ların bütünlüğü kritik
3. **State management:** Session state, prepared statements'ın kontrolü
4. **Failover detection:** PgBouncer'ın failover'ı algılama gecikmesi riski

### 5. Best Practices

#### ✅ PgBouncer İle Kullanılabilir:
- **SELECT-only queries** (okuma işlemleri)
- **Basit INSERT/UPDATE** (tek statement transaction)
- **Stateless transactions** (prepared statement kullanmayan)

#### ❌ PgBouncer Bypass Edilmeli:
- **Critical write operations** (finansal, audit)
- **Multi-statement transactions** (data integrity kritik)
- **Prepared statements** kullanan yazma işlemleri
- **Zero Data Loss garantisi** gereken işlemler

#### 🔄 Alternative: Session Pooling
Eğer PgBouncer ile yazma işlemleri gerekiyorsa:
- `pool_mode = session` kullan (ama daha fazla connection gerekir)
- Veya **application-level** connection pooling (örn: Django, Rails built-in pools)

### 6. Bizim Test Stratejimiz

**Mevcut yaklaşım:**
- ✅ **Read tests:** PgBouncer üzerinden (QPS testleri)
- ✅ **Write tests:** Direkt DB ILB (Zero Data Loss)
- ✅ **Failover under load:** PgBouncer üzerinden (SELECT-only)

**Neden bu yaklaşım?**
1. **Real-world scenario:** Production'da genelde bu şekilde:
   - Apps → PgBouncer (read-heavy workload)
   - Admin/ETL → Direct DB (write operations)
2. **Test accuracy:** Zero Data Loss test'in garantisini bozmadan doğru sonuç
3. **Performance:** PgBouncer'ın connection pooling avantajını test eder

## Kaynaklar ve Referanslar

- [PgBouncer Official Docs - Pool Modes](https://www.pgbouncer.org/config.html#pool_mode)
- [Microsoft Azure - PgBouncer Best Practices](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-connection-pooling-best-practices)
- [PgBouncer Transaction Pooling Limitations](https://www.pgbouncer.org/features.html#transaction-pooling)

