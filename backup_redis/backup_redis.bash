#!/bin/bash
# vim: set noexpandtab tabstop=4 list listchars=tab\:>- :

# 自身の絶対パスを取得
get_abs_path() { echo $(cd $(dirname $0);pwd) ; }

#==========================================================================
# 全体設定
#==========================================================================
# ベースディレクトリ
readonly BASE_DIR="$(get_abs_path)"

# dump ファイル一時取得領域
readonly TMP_DIR="$BASE_DIR/tmp"

# バックアップ設定
readonly application="/var/lib/redis3/dump.rdb"
readonly backup_env="prod"
readonly redis_s3bucket=""

# aws-cli 実行時の環境変数設定（実行時のみ一時的にセット）
readonly AWS_ENV="env AWS_DEFAULT_REGION=ap-northeast-1"

# メール
readonly MAIL_TO="example@example.com"
readonly MAIL_FROM="example@example.com"

TAR="$(which tar)"

#==========================================================================
# エラー処理用
#==========================================================================
LOG_FILE="$BASE_DIR/backup_redis.log"

logger() { /usr/bin/logger -s -t "$(date "+%Y/%m/%d %H:%M:%S")" "$@" 2>>$LOG_FILE ; }
logInfo() {  logger "[info]" "$@" ; }
logError() {  logger "[Error]" "$@" ; }
errorContinue() { logError "$@" ; continue ; }

#==========================================================================
# 関数
#==========================================================================
function sendMail() {
    local mailbody="$1"
    local subject="$2"
    local result="$3"

/usr/sbin/sendmail -t <<_EOM_
Content-Type: text/plain; charset="ISO-2022-JP"
Content-Transfer-Encoding: 7bit
From: ${MAIL_FROM}
Subject: $(echo -e "${subject}" | $(which nkf) -j)
To: ${MAIL_TO}

$(echo -e "${mailbody}" | $(which nkf) -j)
_EOM_
}

getDate() { date "+%Y%m%d%H%M%S" ; }
getBackupApplication() { echo "$1" | /bin/awk '{print $1}' ; }
getBackupEnv() { echo "$1" | /bin/awk '{print $2}' ; }
getBackupDir() { echo "$1" | /bin/awk '{print $3}' ; }
getBackuplog() { cat $LOG_FILE ; }
deleteBackuplog() { rm -f $LOG_FILE ; }

isSuccess() {
    local error_count=$(grep Error $LOG_FILE | wc -l)
    if [ "$error_count" == "0" ]; then
        echo 0
    else
        echo 1
    fi
}

run() {
    local backup_file_name="$1"

    logInfo "### アプリケーション一式 のバックアップ開始。 ###"

    # ログ損失（メールが送られなかった等）を防ぐため、初回に前回実行時ログを削除する
    deleteBackuplog

        # 取得するダンプファイル名
        backup_file_name="${backup_file_name}_${backup_env}.dump.gz"

        logInfo "=== Redis Instance backupを開始 ==="

        # アプリケーション一式
        logInfo "バックアップ開始。"
        $TAR -czf ${TMP_DIR}/${backup_file_name} $application
        if [ "${PIPESTATUS[0]}" -ne 0 ];then
            errorContinue "バックアップ取得に失敗。";
        fi
        logInfo "バックアップ取得完了。"

        # S3 へ転送
        logInfo "$backup_file_name  ファイルを S3 へ転送開始。"
        loginfo "$AWS_ENV aws s3 cp ${TMP_DIR}/${backup_file_name} s3://$redis_s3bucket/"
        ${AWS_ENV} aws s3 cp ${TMP_DIR}/${backup_file_name} s3://$redis_s3bucket/ || { errorContinue "$backup_file_name ファイルの S3 転送に失敗しました。"; }
        logInfo "$backup_file_name ファイル転送完了。"

        # 転送ファイルサイズチェック
        sleep 60
        logInfo "転送元ファイルと転送先ファイルのサイズ比較開始。"
        local_file_size=$(ls -l ${TMP_DIR}/${backup_file_name} | awk '{print $5}')
        s3_file_size=$($AWS_ENV aws s3 ls s3://${redis_s3bucket}/${backup_file_name} | awk '{print $3}')
        [ "${local_file_size}" = "${s3_file_size}" ] || { errorContinue "転送元ファイル（$local_file_size）と転送先ファイル（$s3_file_size）のサイズ不一致。"; }
        logInfo "転送元ファイル（$local_file_size）と転送先ファイル（$s3_file_size）のサイズ一致。"

        # ダンプファイル削除
        rm -f ${TMP_DIR}/${backup_file_name}
        logInfo "転送元ファイル（$backup_file_name）を削除。"

        logInfo "=== Redis Instance backupを終了 ===\n"

}

# バックアップファイル名（YYYYMMDDHH24MISS）
BACKUP_FILE_NAME=$(getDate)

RESULT_MESSAGE=$(run "$BACKUP_FILE_NAME" 2>&1)
is_success=$(isSuccess)
if [ $is_success -ne 0 ]; then
    logError "### Redis のバックアップ異常終了。 ###"

    # Warning: Using a password on the command line interface can be insecure. を結果から除外する
    RESULT_MESSAGE=${RESULT_MESSAGE//Warning: Using a password on the command line interface can be insecure./}

    MAIL_BODY=$(getBackuplog)
    sendMail "$MAIL_BODY" "Redis バックアップ：異常終了（エラーあり）" "$RESULT_MESSAGE"

    exit $ERROR_CODE
else
    logInfo "### Redis のバックアップ正常終了。 ###"

    # Warning: Using a password on the command line interface can be insecure. を結果から除外する
    RESULT_MESSAGE=${RESULT_MESSAGE//Warning: Using a password on the command line interface can be insecure./}

    MAIL_BODY=$(getBackuplog)
    sendMail "$MAIL_BODY" "Redis バックアップ：正常終了" "$RESULT_MESSAGE"

    exit 0
fi
