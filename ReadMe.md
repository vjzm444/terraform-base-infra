-실행하는 순서

1. terraform init 최초 1번후

1-1. varlidation 필수값 변경
1-2. terraform plan 확인
1-3. terraform apply 적용


2.0 장한결 RDS 설정

2-1. [데이터베이스 생성]
Azure DB(Master): 마스터 DB 생성 (사설 IP 할당).
AWS RDS(Slave): Private Subnet에 슬레이브 DB 생성.

2-2. [인프라/네트워크]
VPN 터널: AWS-Azure 간 Site-to-Site VPN 연결 설정.

2-3. [데이터 복제]
복제 연결: AWS RDS에서 Azure DB를 마스터로 바라보도록 Replica 설정 적용 (스크립트 실행).

2-4. [프록시 서버]
HAProxy EC2: AWS 내부 Private IP를 가진 프록시 서버 생성.(프록시서버는 aws에 놓는다)
설정 파일: Azure DB와 AWS RDS의 사설 IP를 등록하고 감시 로직 적용.


3-1. 쿠버네티스 ALB 띄우기...
3-2. 쿠버네티스 ALB Log보내기(로그그룹: /ec2/vamserlike-backend에 전송되야함)

2번째 테라폼 배포
4. cognito 생성 -> clientid, poolid 출력됨
5-1. apigateway 생성(9개의 API모두 ALB와 연결한다. CORS 체크다 되어야함)


6. [백엔드 재배포]
- 변경점1: DB 프록시 주소 변경.
- 변경점2: Cognito :clientid, poolid 변경
-> 최종  백엔드깃 변경. 파이어호스 연결되어, 백엔드 자동 다시 올라감


6-1. 유니티 깃 url변경
-> 최종  백엔드깃 변경. 파이어호스 연결되어, 백엔드 자동 다시 올라감

7. 클라우드워치logs -> S3로전송한다, firehose.yml(CloudFormation)

8. Athena-Grafana연결 방법
8-1. 기영 Grafana Url로 접속
8-2. Connections -> Add new connection -> Athena install -> 이하처럼 셋팅
- Default Region: ap-northeast-2
- Data source: AwsDataCatalog
- database: web_logs_db
- database: primary
- Output Location: s3://{너의AccountId}-vamserlike-backend-logs/athena-results/
8-3. Dashboard메뉴 -> import -> grafana-vamserlike-backend.json 선택 -> 쿼리 최초1번 Run실행



9. 자원회수
9-1. CloudFormation의 스택삭제.
9-2. terraform destroy

