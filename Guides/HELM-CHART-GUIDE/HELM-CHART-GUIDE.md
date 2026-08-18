# دليل الـ Helm Chart — VProfile

مرجع قبل الـ Deploy. الملف ده مكتوب من **الملفات الفعلية** الموجودة في `helm/vprofile/` عند commit `8e187ce` — مفيش فيه ملف متخيّل ولا resource مش موجود.

---

## 0. مصطلحات لازم نتفق عليها الأول

قبل أي حاجة، دي الكلمات اللي هتتكرر:

| المصطلح | يعني إيه |
|---|---|
| **Kubernetes manifest** | ملف YAML بيوصف حاجة عايزها في الكلاستر (Pod، Service، ...). |
| **Helm** | أداة بتاخد ملفات YAML **فيها فراغات**، بتملا الفراغات بقيم، وبتبعت الناتج للـ Kubernetes. |
| **Chart** | مجلد بالشكل اللي Helm بيفهمه: `Chart.yaml` + `values.yaml` + `templates/`. |
| **Template** | ملف YAML فيه فراغات بالشكل `{{ ... }}`. |
| **Rendering** | عملية ملء الفراغات → ناتجها YAML عادي نضيف. |
| **Release** | نسخة **مثبّتة** من الـ chart في الكلاستر، ليها اسم. عندنا اسمها `vprofile`. |
| **Resource** | الحاجة اللي بتتخلق فعلاً جوه Kubernetes بعد ما الـ manifest يتبعت. |

**الفكرة كلها في سطر:** الـ Chart هو **قالب**، والـ Release هو **النسخة المطبوعة** منه.

---

## 1. شكل الـ Chart الفعلي

```
helm/vprofile/
├── Chart.yaml                    ← بطاقة تعريف الـ chart
├── values.yaml                   ← القيم الافتراضية
└── templates/
    ├── _helpers.tpl              ← دوال مشتركة (مش manifest)
    ├── NOTES.txt                 ← رسالة بعد التثبيت (مش manifest)
    ├── 10-db01.yaml              ← MySQL
    ├── 20-mc01.yaml              ← Memcached
    ├── 30-rmq01.yaml             ← RabbitMQ
    ├── 40-app01.yaml             ← Tomcat
    ├── 50-vproweb.yaml           ← Nginx
    └── 60-ingress.yaml           ← ALB
```

**10 ملفات. مفيش غيرهم.**

### الـ resources اللي بتتخلق فعلاً

| النوع | العدد | فين |
|---|---|---|
| Service | 5 | كل ملف component |
| Deployment | 4 | mc01, rmq01, app01, vproweb |
| StatefulSet | 1 | db01 |
| Ingress | 1 | 60-ingress |
| Secret | 0 أو 1 | حسب الإعداد (تحت) |

**المجموع: 11 أو 12 object.**

### وحاجات سألت عنها ومش موجودة

| | الحالة |
|---|---|
| **ConfigMap** | ❌ **مفيش ولا واحد.** كل الإعداد إما محروق في الصورة وقت الـ build، أو جاي من Secret. |
| **NetworkPolicy** | ❌ **مفيش.** ولو ضفتها دلوقتي **مش هتشتغل** — لأن `vpc-cni` عندك لسه `enableNetworkPolicy` مقفولة (شغل terraform مش الـ chart). |
| **PersistentVolumeClaim** | ⚠️ **مفيش object باسمه في الـ chart** — بس بيتخلق PVC فعلاً. الشرح في قسم 4. |
| **Chart.lock / charts/** | ❌ مفيش dependencies، فمفيش الملفات دي. |

مهم متدوّرش على ملفات مش موجودة وتفتكر إنك ضيّعتها.

---

## 2. شرح كل ملف

### 2.1 `Chart.yaml`

**الوظيفة العامة:** بطاقة تعريف الـ chart. ده الملف اللي وجوده بيقول لـ Helm "المجلد ده chart".

**الهدف من وجوده:** إلزامي — من غيره Helm بيرفض المجلد أصلاً.

**بيحتوي إيه:** `apiVersion: v2` (صيغة Helm 3)، `name: vprofile`، `version: 1.0.0` (نسخة الـ **chart** نفسه)، `appVersion: "2.0"` (نسخة الـ **تطبيق** — معلومة توثيقية بس)، وصف، واسم الـ maintainer.

**بيعتمد على:** لا شيء.

**اللي بيعتمد عليه:** `_helpers.tpl` بيقرا منه `.Chart.Name` و`.Chart.Version` عشان يبني label، و`NOTES.txt` بيقرا `.Chart.AppVersion`.

**علاقته بالباقي:** نقطة الدخول. Helm بيقراه الأول.

> ملاحظة عامة (مش من مشروعك): `Chart.yaml` ممكن يشيل قسم `dependencies:` لو الـ chart بيعتمد على charts تانية — وده اللي اتكلمنا عنه في فكرة الـ umbrella للـ platform. **مفيش قسم dependencies في الـ chart ده.**

---

### 2.2 `values.yaml`

**الوظيفة العامة:** كل القيم اللي ممكن تتغير من نشرة لنشرة، في مكان واحد.

**الهدف:** فصل **الشكل** (في `templates/`) عن **القيم** (هنا). عشان تنشر نفس الـ chart على dev وprod بقيم مختلفة من غير ما تلمس template.

**بيحتوي إيه — 7 أقسام:**

| القسم | بيتحكم في |
|---|---|
| `image` | الـ registry والـ tag وسياسة السحب — **فاضيين افتراضياً بقصد** |
| `db` | اسم قاعدة البيانات + مصدر الباسورد |
| `storage` | اسم الـ StorageClass وحجم الـ volume |
| `ingress` | تفعيل، class، scheme، مسار الـ health check |
| `app` / `web` | عدد النسخ + الموارد |
| `database` / `memcached` / `rabbitmq` | الموارد |

**بيعتمد على:** لا شيء.

**اللي بيعتمد عليه:** **كل ملف** في `templates/`.

**نقطة تصميم مهمة:** `image.registry` و`image.tag` **فاضيين**. مش نسيان — لو الـ pipeline نسي يبعتهم، الـ render **بيفشل برسالة واضحة** بدل ما ينشر صورة غلط. نفس المنطق على الباسورد.

---

### 2.3 `templates/_helpers.tpl`

**الوظيفة العامة:** دوال مشتركة. **مش manifest** — عمره ما هيطلع منه Kubernetes object.

**ليه اسمه بادئ بـ `_`؟** ده اتفاق في Helm: أي ملف في `templates/` اسمه بيبدأ بـ `_` بيتعامل معاه كـ **قطعة كود** مش كـ manifest. لو شيلت الـ underscore، Helm هيحاول يفسّره كـ YAML وهيفشل.

**بيحتوي 4 دوال:**

| الدالة | بتعمل إيه | بيستخدمها مين |
|---|---|---|
| `vprofile.labels` | بتطبع 3 labels ثابتة | كل الـ 5 ملفات |
| `vprofile.image` | بتبني اسم الصورة كامل، **وبتفشل** لو الـ registry أو tag ناقص | الـ 5 components |
| `vprofile.dbSecretName` | بترجّع اسم الـ Secret — سواء بتاعك أو اللي الـ chart عمله | `10-db01`, `40-app01` |
| `vprofile.requireDbSecret` | **بتوقف الـ render** لو مفيش أي مصدر للباسورد | `10-db01` |

**بيعتمد على:** `values.yaml` (بيقرا `.Values.image.*` و`.Values.db.*`) و`Chart.yaml`.

**اللي بيعتمد عليه:** الست ملفات manifest.

**ليه موجود؟** يمنع التكرار (الـ labels في 12 مكان)، **ويضمن الاتساق**. أهم مثال: `vprofile.dbSecretName` بيستخدمها `db01` و`app01` الاتنين — فمستحيل واحد يشاور على Secret والتاني على Secret تاني.

---

### 2.4 `templates/10-db01.yaml` — MySQL

**الوظيفة:** قاعدة البيانات وتخزينها الدائم.

**بيحتوي 3 objects** (أو 2):

| # | Object | ملاحظة |
|---|---|---|
| 1 | `Secret` **مشروط** | بيتخلق **بس** لو `db.existingSecret` فاضية |
| 2 | `Service` اسمه `db01` | **headless** (`clusterIP: None`) |
| 3 | `StatefulSet` اسمه `db01` | replica واحدة + `volumeClaimTemplates` |

**الأقسام المهمة جوه الـ StatefulSet:**
- `envFrom.secretRef` → بيسحب `MYSQL_ROOT_PASSWORD` من الـ Secret
- `volumeMounts` على `/var/lib/mysql`
- `readinessProbe` و`livenessProbe` بـ `mysqladmin ping` **بالباسورد**
- `volumeClaimTemplates` ← ده اللي بيعمل الـ PVC

**بيعتمد على:** `values.yaml` (db, storage, database) + `_helpers.tpl` (3 دوال) + صورة `vprofile-db` في ECR + **StorageClass اسمها `gp3` موجودة في الكلاستر**.

**اللي بيعتمد عليه:** `40-app01` بيستنى `db01:3306` ويستخدم نفس الـ Secret.

**ليه StatefulSet مش Deployment؟** الـ Deployment بيعامل الـ pods كنسخ متطابقة قابلة للاستبدال. قاعدة البيانات **مش كده** — ليها بيانات على قرص لازم يفضل. الـ StatefulSet بيدّي الـ pod **اسم ثابت** (`db01-0`) و**قرص ثابت** بيتعلّق بيه كل مرة.

---

### 2.5 `templates/20-mc01.yaml` — Memcached

**الوظيفة:** كاش في الذاكرة.

**بيحتوي:** `Service` اسمه `mc01` + `Deployment` بـ replica واحدة.

**بيعتمد على:** `values.yaml` (image, memcached) + `_helpers.tpl` + صورة `vprofile-mc`.

**اللي بيعتمد عليه:** `40-app01` (بيستنى `mc01:11211`).

**ليه Deployment؟** الكاش **بيانات مؤقتة**. لو الـ pod مات، تضيع ويتبني تاني من الـ DB. مفيش تخزين، فمفيش داعي لـ StatefulSet.

---

### 2.6 `templates/30-rmq01.yaml` — RabbitMQ

**الوظيفة:** طابور رسائل.

**بيحتوي:** `Service` اسمه `rmq01` + `Deployment` بـ replica واحدة، وprobe بـ `rabbitmq-diagnostics`.

**بيعتمد على:** `values.yaml` (image, rabbitmq) + `_helpers.tpl` + صورة `vprofile-rmq`.

**اللي بيعتمد عليه:** `40-app01`.

**ملاحظة:** مفيش credentials هنا — الـ app بيتصل بـ `guest/guest` وهي القيمة الافتراضية للصورة.

---

### 2.7 `templates/40-app01.yaml` — Tomcat (قلب التطبيق)

**الوظيفة:** التطبيق نفسه.

**بيحتوي:** `Service` اسمه `app01` على 8080 + `Deployment` بـ **نسختين**.

**أهم 3 أقسام:**

**`initContainers`** — حاوية `busybox` بتقف تستنى `db01` و`mc01` و`rmq01` يفتحوا بورتاتهم. الـ Tomcat مبيبدأش قبل ما دي تخلص.
> ليه؟ Spring بيبني اتصال قاعدة البيانات **وقت بدء التشغيل**. لو الـ DB مش جاهزة، الـ context بيفشل، و**Tomcat بيفضل يرد 404 لباقي عمر الـ pod** — مبيعملش crash فالـ Kubernetes مش هيعيد تشغيله. الانتظار هنا أرخص من عطل صامت.

**`env.JDBC_PASSWORD`** — بياخد الباسورد من نفس الـ Secret بتاع `db01`، وبيتغلّب على القيمة المحروقة جوه الـ WAR.

**الـ probes على `/login`** — مش على `/`، لأن Tomcat بيرجّع تحويل (302) من `/` والـ probe بيقراه فشل.

**بيعتمد على:** `values.yaml` (image, app, db) + `_helpers.tpl` + صورة `vprofile-app` + **الـ Services التلاتة تكون موجودة** + الـ Secret.

**اللي بيعتمد عليه:** `50-vproweb` بيوجّه له.

---

### 2.8 `templates/50-vproweb.yaml` — Nginx

**الوظيفة:** الواجهة الأمامية، بتوجّه الطلبات لـ `app01`.

**بيحتوي:** `Service` نوعه **NodePort** اسمه `vproweb` + `Deployment` بنسختين.

**ليه NodePort مش LoadBalancer؟** لو خليته `LoadBalancer`، Kubernetes هيطلّع **موزّع أحمال تاني** بجانب الـ ALB اللي الـ Ingress بيعمله — وتدفع مرتين على حاجة واحدة.

**بيعتمد على:** `values.yaml` (image, web) + `_helpers.tpl` + صورة `vprofile-web` + **وجود Service اسمها `app01`** (لأن `nginx.conf` محروق فيها).

**اللي بيعتمد عليه:** `60-ingress` بيوجّه له.

---

### 2.9 `templates/60-ingress.yaml` — ALB

**الوظيفة:** الباب الخارجي. بيقول للـ AWS Load Balancer Controller "اعمل ALB يوصل للتطبيق ده".

**بيحتوي:** `Ingress` واحد، ملفوف في شرط `{{- if .Values.ingress.enabled }}`.

**الأقسام:** annotations بتوصف الـ ALB (`scheme`, `target-type: ip`, `healthcheck-path`, `success-codes`)، و`ingressClassName: alb`، وقاعدة توجيه `/` → `vproweb:80`.

**بيعتمد على:** `values.yaml` (ingress) + `_helpers.tpl` + **الـ AWS Load Balancer Controller يكون متنصّب** + **Service اسمها `vproweb`**.

**اللي بيعتمد عليه:** لا شيء — آخر حلقة.

**⚠️ ده الـ object الوحيد اللي بيكلّف فلوس مباشرة** (~$0.65/يوم). و`ingress.enabled=false` بيلغيه تماماً.

---

### 2.10 `templates/NOTES.txt`

**الوظيفة:** الرسالة اللي بتظهر بعد `helm install`.

**مش manifest** — Helm بيعامله كحالة خاصة: بيرندره ويطبعه في الترمينال وخلاص، **مبيبعتوش للكلاستر**.

**بيحتوي:** رسالة فيها الـ tag، وأوامر متابعة الـ pods، وأمر جلب عنوان الـ ALB.

**بيعتمد على:** `values.yaml` + `Chart.yaml` + `.Release.Namespace`.

---

## 3. العلاقات — إزاي كل ده بيشتغل مع بعض

### 3.1 إزاي `values.yaml` بيأثر على الـ templates

الـ template بيقول:
```yaml
replicas: {{ .Values.app.replicas }}
```

`.Values` = محتوى `values.yaml` كله كشجرة. `.Values.app.replicas` = انزل على `app` وبعدين `replicas`. لما Helm يرندر، بيحط `2` مكان القوس.

**ترتيب الأولوية عند التعارض** — من الأقوى:

```
1. --set image.tag=abc        ← سطر الأوامر (الأقوى)
2. -f my-values.yaml          ← ملف إضافي
3. values.yaml                ← الافتراضي (الأضعف)
```

فلما تكتب `--set image.tag=abc12345-7`، دي بتتغلّب على الفاضي اللي في `values.yaml`.

### 3.2 دور `_helpers.tpl`

الـ template بيقول:
```yaml
labels: {{- include "vprofile.labels" . | nindent 4 }}
```

- `include "vprofile.labels"` = شغّل الدالة دي
- `.` = ابعتلها كل السياق (عشان توصل لـ `.Values` و`.Chart`)
- `| nindent 4` = خد الناتج وزحزحه 4 مسافات عشان الـ YAML يفضل سليم

**Helm بيحمّل كل الملفات الأول ويبني فهرس بالأسماء، وبعدين بيرندر.** فمكان الملف مالوش أي دخل — التطابق بالاسم.

### 3.3 إزاي Helm بيعمل rendering

```
1. اقرا Chart.yaml            → دي chart اسمها vprofile
2. اقرا values.yaml           → القيم الافتراضية
3. ادمج --set و -f فوقها      → القيم النهائية
4. حمّل كل ملفات templates/   → ابنِ فهرس الدوال من _.tpl
5. رندر كل ملف                → املا كل {{ }}
   └─ لو فيه fail أو required ناقصة → قف هنا، مفيش أي حاجة اتبعتت
6. الناتج = YAML عادي         → ده بالظبط اللي helm template بيوريهولك
7. ابعته للـ Kubernetes API
```

**النقطة 5 مهمة:** لو الـ render فشل، **مفيش أي حاجة بتتبعت**. مفيش نشر نصّه — إما الكل أو لا شيء.

### 3.4 `helm install` بيعمل إيه

```bash
helm install vprofile helm/vprofile -n vprofile
```

1. يرندر (زي فوق)
2. يبعت الـ manifests للـ API server
3. يخزّن **Release** اسمها `vprofile` كـ Secret جوه الـ namespace — ده سجل Helm عن اللي نشره
4. يطبع `NOTES.txt`

**بيفشل لو الـ release بنفس الاسم موجودة.**

### 3.5 `helm upgrade --install` بيعمل إيه — وده اللي بنستخدمه

```bash
helm upgrade --install vprofile helm/vprofile -n vprofile --set ...
```

- **مش موجودة؟** يتصرف زي `install` بالظبط
- **موجودة؟** يرندر بالقيم الجديدة، **يقارن بالنسخة السابقة**، ويبعت **الفرق بس**
- الـ revision بتزيد (1 → 2 → 3)، فتقدر ترجّع بـ `helm rollback`

**ليه بنستخدمه دايماً؟** لأنه **آمن للتكرار** — نفس الأمر يشتغل أول مرة وتاني مرة وعاشر مرة. وده اللي بيخلي الـ pipeline يقدر ينده عليه من غير ما يسأل "هي متنصّبة قبل كده ولا لأ".

### 3.6 العلاقة بين ملفات Helm والـ Kubernetes resources

| الملف | بيولّد | Kubernetes بيعمل بيها إيه |
|---|---|---|
| `10-db01.yaml` | Secret + Service + StatefulSet | StatefulSet بيعمل pod `db01-0` وPVC |
| `20-mc01.yaml` | Service + Deployment | Deployment بيعمل ReplicaSet بيعمل pod |
| `30-rmq01.yaml` | Service + Deployment | نفس الحاجة |
| `40-app01.yaml` | Service + Deployment | Deployment بيعمل **2 pods** |
| `50-vproweb.yaml` | Service + Deployment | Deployment بيعمل **2 pods** |
| `60-ingress.yaml` | Ingress | الـ LB Controller بيقراها ويعمل **ALB في AWS** |

**نقطة أساسية:** Helm **بيبعت manifests وخلاص**. اللي بيعمل الـ pods والـ volumes والـ ALB هو **Kubernetes وcontrollers جواه**. Helm مش موجود في الصورة بعد لحظة الإرسال.

### 3.7 العلاقات بين الـ resources نفسها

**Deployment ← Pod**
الـ Deployment مبيعملش pods مباشرة. بيعمل **ReplicaSet**، والـ ReplicaSet بيعمل الـ pods. لما تحدّث الصورة، بيعمل ReplicaSet جديد وينقل الـ pods بالتدريج.

**StatefulSet ← Pod ← PVC**
```
StatefulSet db01
  └─ Pod db01-0                      ← اسم ثابت (مش عشوائي)
       └─ PVC data-db01-0            ← من volumeClaimTemplates
            └─ PersistentVolume      ← اتعمل أوتوماتيك
                 └─ EBS volume في AWS
```
**دي إجابة سؤالك عن الـ PVC:** مفيش ملف PVC في الـ chart. الـ `volumeClaimTemplates` جوه الـ StatefulSet هي اللي بتخلّي Kubernetes يعمل PVC **لكل pod**، بالاسم `data-db01-0`. والـ PVC ده **بيعيش بعد ما تمسح الـ release** — بقصد، عشان متفقدش البيانات بالغلط.

**Service ← Pod (بالـ labels مش بالاسم)**
```yaml
# في الـ Service
selector:
  app: db01
# في الـ Pod
labels:
  app: db01
```
الـ Service بيسأل "هاتلي كل pod عليه `app: db01`" — ومش مهم اسم الـ pod ولا على أنهي نود. أي pod بالـ label ده بيدخل. **لو الاتنين مش متطابقين، الـ Service بيبقى فاضي والاتصال بيفشل بدون أي رسالة.**

**Pod ← Secret** — بطريقتين في المشروع:
```yaml
# db01: كل مفاتيح الـ Secret تبقى متغيرات
envFrom:
  - secretRef: { name: db01-credentials }

# app01: مفتاح واحد باسم متغير مختلف
env:
  - name: JDBC_PASSWORD
    valueFrom:
      secretKeyRef: { name: db01-credentials, key: MYSQL_ROOT_PASSWORD }
```

**Ingress ← Service**
```
Ingress → vproweb:80 → pods بـ label app: vproweb
```
الـ Ingress **بيشاور على اسم Service**. لو الـ Service مش موجودة، الـ ALB بيتعمل من غير أهداف صحية.

**Pod ← ConfigMap** — **مش مستخدمة في المشروع.** كل الإعداد محروق في الصور أو جاي من Secret.

**السلسلة كاملة:**
```
مستخدم → ALB → Ingress → Service vproweb → pods nginx
                                              ↓
                                    Service app01 → pods tomcat
                                              ↓
                            Services db01 / mc01 / rmq01
                                              ↓
                                    pod db01-0 → PVC → EBS
```

---

## 4. المتطلبات قبل الـ Deploy

### لازم يكونوا موجودين قبل ما تدوس

| المتطلب | ليه | إزاي تتأكد |
|---|---|---|
| نودز شغالة | مفيش نودز = كل الـ pods `Pending` | `kubectl get nodes` |
| الـ 5 صور في ECR | بالـ tag اللي هتبعته | `aws ecr describe-images ...` |
| **StorageClass اسمها `gp3`** | من غيرها الـ PVC يقعد `Pending` للأبد | `kubectl get sc` |
| **AWS Load Balancer Controller** | من غيره الـ Ingress **يتقبل ومحصلش ALB** | `kubectl -n kube-system get deploy` |
| Namespace `vprofile` | أو `--create-namespace` | `kubectl get ns` |
| **Secret فيه `MYSQL_ROOT_PASSWORD`** | من غيره الـ render يفشل | `kubectl -n vprofile get secret` |
| kubeconfig لليوزر الصح | مختلف بين `ssm-user` و`jenkins` | `kubectl get nodes` |
| **تكون على الـ Jenkins box** | الـ endpoint خاص — مفيش وصول من اللابتوب | — |

**أول اتنين في القائمة بييجوا من `platform/bootstrap-addons.sh`** — عشان كده بيتشغّل **قبل** الـ chart.

### الأمر الكامل

```bash
kubectl -n vprofile create secret generic db01-credentials \
  --from-literal=MYSQL_ROOT_PASSWORD='<باسورد قوي>'

helm upgrade --install vprofile helm/vprofile \
  --namespace vprofile --create-namespace \
  --set image.registry="<acct>.dkr.ecr.eu-west-3.amazonaws.com" \
  --set image.tag="<git-sha>-<build>" \
  --set db.existingSecret=db01-credentials \
  --timeout 10m
```

---

## 5. أوامر Helm في المشروع

### المستخدمة فعلاً

| الأمر | بيعمل إيه |
|---|---|
| `helm lint <chart>` | فحص سريع للتركيب. **تحذير: بيعدّي حتى لو الـ chart مش هيطلّع أي حاجة** |
| `helm template <name> <chart> --set ...` | **يرندر ويطبع من غير ما يبعت أي حاجة للكلاستر.** أهم أمر للمراجعة قبل النشر |
| `helm upgrade --install <name> <chart> -n <ns> --set ...` | التثبيت والتحديث. آمن للتكرار |
| `helm uninstall <name> -n <ns>` | يشيل كل الـ resources **ومعاها الـ ALB**. الـ PVC **بيفضل** |
| `helm repo add eks https://aws.github.io/eks-charts` | يضيف مستودع خارجي — في `bootstrap-addons.sh` |
| `helm upgrade --install aws-load-balancer-controller eks/... --wait` | تثبيت الـ LB Controller |

### مفيدة وقت المشاكل

| الأمر | بيعمل إيه |
|---|---|
| `helm list -n vprofile` | إيه المنشور وأنهي revision |
| `helm status vprofile -n vprofile` | حالة الـ release + رسالة NOTES |
| `helm get manifest vprofile -n vprofile` | الـ YAML اللي اتبعت **فعلاً** — للمقارنة مع اللي متوقعه |
| `helm get values vprofile -n vprofile` | القيم اللي اتستخدمت فعلاً |
| `helm history vprofile -n vprofile` | كل النسخ السابقة |
| `helm rollback vprofile <revision> -n vprofile` | رجوع لنسخة قديمة |
| `helm diff upgrade ...` | يوريك الفرق قبل التطبيق — **محتاج plugin مش متنصّب عندك** |

### فلاجات مهمة

| | |
|---|---|
| `--set k=v` | تعديل قيمة واحدة، أعلى أولوية |
| `-n <ns> --create-namespace` | الـ namespace، ويعمله لو مش موجود |
| `--timeout 10m` | أقصى انتظار |
| `--wait` | متخرجش قبل ما كل حاجة تبقى Ready — مستخدمة مع الـ LB Controller |
| `--atomic` | لو فشل، ارجع تلقائياً. **متستخدمهاش في أول deploy** — بيمسح الـ pods اللي محتاج تفحصها |
| `--dry-run` | يرندر ويتحقق مع الـ API من غير ما يعمل حاجة |

---

## 6. خريطة العلاقات

```
                      helm/vprofile/
                            │
      ┌─────────────────────┼─────────────────────┐
      │                     │                     │
  Chart.yaml           values.yaml          templates/
  (تعريف)              (القيم)              (الشكل)
      │                     │                     │
      └──────────┬──────────┘                     │
                 │                                │
                 └────────────┬───────────────────┘
                              ↓
                      ┌───────────────┐
                      │ HELM RENDERING│  ← _helpers.tpl بتشتغل هنا
                      │  {{ }} → قيم  │  ← --set بيتغلّب على values.yaml
                      └───────┬───────┘  ← required / fail بيوقفوا هنا
                              ↓
                   Kubernetes Manifests (YAML عادي)
                              ↓
                    Kubernetes API Server
                              ↓
      ┌──────────┬──────────┬─────────┬──────────┐
   Secret     Services   Deployments StatefulSet Ingress
   (1)         (5)          (4)         (1)       (1)
      │          │           │           │          │
      │          │           ↓           ↓          ↓
      │          │      ReplicaSets    Pod        ALB
      │          │           ↓        db01-0    (في AWS)
      │          │         Pods          ↓          │
      │          │      (2 app01,       PVC         │
      │          │       2 vproweb,      ↓          │
      │          │       1 mc01,         PV         │
      │          │       1 rmq01)        ↓          │
      │          │                  EBS Volume      │
      │          └── بتوصل الـ pods ──┘              │
      └── بتحقن الباسورد في db01-0 و app01 ──┘      │
                                                     │
   المستخدم ──────────────────────────────────────┘
        ↓
   ALB → vproweb (nginx) → app01 (tomcat) → db01/mc01/rmq01
        ↓
   تطبيق VProfile شغال
```

### الترتيب الزمني للتشغيل

```
1. db01-0 يقوم       → PVC يتربط → MySQL يشتغل → Ready
2. mc01 / rmq01      → Ready
3. app01 initContainer يستنى التلاتة → يخلص
4. app01 tomcat يقوم → Spring يتصل بالـ DB → /login = 200 → Ready
5. vproweb يقوم      → nginx يحل اسم app01 → Ready
6. الـ LB Controller يشوف الـ Ingress → ALB (2-3 دقايق)
7. الـ ALB يفحص /login = 200 → targets healthy
8. الموقع شغال
```

---

## 7. جدول مرجعي سريع

| الملف | بيعمل | بيعتمد على | بيعتمد عليه |
|---|---|---|---|
| `Chart.yaml` | تعريف | — | `_helpers`, `NOTES` |
| `values.yaml` | قيم | — | **كل الـ templates** |
| `_helpers.tpl` | 4 دوال | values, Chart | الـ 6 manifests |
| `10-db01.yaml` | Secret? + Svc + StatefulSet | values, helpers, gp3 SC | `40-app01` |
| `20-mc01.yaml` | Svc + Deploy | values, helpers | `40-app01` |
| `30-rmq01.yaml` | Svc + Deploy | values, helpers | `40-app01` |
| `40-app01.yaml` | Svc + Deploy | values, helpers, db01/mc01/rmq01, Secret | `50-vproweb` |
| `50-vproweb.yaml` | Svc + Deploy | values, helpers, `app01` | `60-ingress` |
| `60-ingress.yaml` | Ingress | values, helpers, `vproweb`, LB Controller | — |
| `NOTES.txt` | رسالة | values, Chart | — |

---

## 8. ثلاث حاجات لو غلطت فيها هتضيع وقت طويل

**1. أسماء الـ Services مش قابلة للتغيير.** `db01` / `mc01` / `rmq01` / `app01` محروقين جوه الصور وقت الـ build. لو غيّرت اسم Service: الـ Helm ينجح، الـ pods تبقى Running، **والتطبيق يقع من غير أي رسالة واضحة**.

**2. الـ Ingress بدون Controller = صمت تام.** الـ Ingress بيتقبل ويتخزّن و`kubectl get ingress` بيوريه — **ومحصلش أي ALB**. مفيش خطأ ولا event. عشان كده الـ `bootstrap-addons.sh` بيفحص وجود الـ CRD.

**3. `helm lint` بيعدّي على chart فاضي.** لو ملفات الـ templates مش جوه مجلد `templates/`، الـ lint بيقول نضيف والـ install بينجح **ومحصلش أي deploy**. الفحص الحقيقي هو:
```bash
helm template x helm/vprofile --set image.registry=r --set image.tag=t \
  --set db.existingSecret=s | grep -c '^kind:'
# لازم يطلع 11
```

---

*مكتوب من الملفات الفعلية في `helm/vprofile/` — commit `8e187ce`.*
