-실행하는 순서

1. terraform init 최초 1번후

1-1. varlidation 필수값 변경
1-2. terraform plan 확인
1-3. terraform apply 적용

2-1. 쿠버네티스 ALB 띄우기...
2-2. 쿠버네티스 ALB Log보내기(로그그룹: /ec2/vamserlike-backend에 전송되야함)

3. CloudFormation으로 firehose.yml 적용하기!!!

4. Athena-Grafana연결 방법
4-1. 기영 Grafana Url로 접속
4-2. Connections -> Add new connection -> Athena install -> 이하처럼 셋팅
- Default Region: ap-northeast-2
- Data source: AwsDataCatalog
- database: web_logs_db
- database: primary
- Output Location: s3://{너의AccountId}-vamserlike-backend-logs/athena-results/
4-3. Dashboard메뉴 -> import -> grafana-vamserlike-backend.json 선택 -> 쿼리 최초1번 Run실행



3. 자원회수
3-1. CloudFormation의 스택삭제.
3-2. terraform destroy

