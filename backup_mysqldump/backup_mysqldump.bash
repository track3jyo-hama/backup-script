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

# 各環境用の設定
readonly mysqldb_identifier=""
readonly mysqldb_db=""
readonly mysqldb_user=""
readonly mysqldb_pass=""
readonly mysqldb_s3bucket=""

# aws-cli 実行時の環境変数設定（実行時のみ一時的にセット）
readonly AWS_ENV="env AWS_DEFAULT_REGION=ap-northeast-1"

# メール
readonly MAIL_TO="example@example.com"
readonly MAIL_FROM="example@example.com"

MYSQL_DUMP="$(which mysqldump)"
MYSQL_DUMP_OPT="--single-transaction"

#==========================================================================
# エラー処理用
#==========================================================================
LOG_FILE="$BASE_DIR/backup_mysqldump.log"

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

/sbin/sendmail -t <<_EOM_
Content-Type: text/plain; charset="ISO-2022-JP"
Content-Transfer-Encoding: 7bit
From: ${MAIL_FROM}
Subject: $(echo -e "${subject}" | $(which nkf) -j)
To: ${MAIL_TO}

$(echo -e "${mailbody}" | $(which nkf) -j)
_EOM_
}

# getDate() { date "+%Y%m%d%H%M%S" ; }
getDate() { date "+%Y%m%d" ; }
getDeleteDate() { date "+%Y%m%d" --date "5 days ago" ; }
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

    logInfo "### DB mysqldump のバックアップ開始。 ###"

    # ログ損失（メールが送られなかった等）を防ぐため、初回に前回実行時ログを削除する
    deleteBackuplog

        # 取得するダンプファイル名
        dump_file_name="${backup_file_name}_${mysqldb_db}.dump.gz"

        logInfo "=== DB Instance Identifier: ${mysqldb_identifier} , DB: ${mysqldb_db} を開始 ==="

        # mysqldump
        logInfo "フルダンプ取得開始。"
        $MYSQL_DUMP -h $mysqldb_identifier -u $mysqldb_user -p"$mysqldb_pass" $MYSQL_DUMP_OPT $mysqldb_db | gzip >${TMP_DIR}/${dump_file_name}
        if [ "${PIPESTATUS[0]}" -ne 0 ];then
            errorContinue "フルダンプ取得に失敗。";
        fi
        logInfo "フルダンプ取得完了。"

        #S3 へ転送
        logInfo "$dump_file_name ファイルを S3 へ転送開始。"
        loginfo "$AWS_ENV aws s3 cp ${TMP_DIR}/${dump_file_name} s3://$mysqldb_s3bucket/"
        ${AWS_ENV} aws s3 cp ${TMP_DIR}/${dump_file_name} s3://$mysqldb_s3bucket/ || { errorContinue "$dump_file_name ファイルの S3 転送に失敗しました。"; }
        logInfo "$dump_file_name ファイル転送完了。"

        # 転送ファイルサイズチェック
        sleep 60
        logInfo "転送元ファイルと転送先ファイルのサイズ比較開始。"
        local_file_size=$(ls -l ${TMP_DIR}/${dump_file_name} | awk '{print $5}')
        s3_file_size=$($AWS_ENV aws s3 ls s3://${mysqldb_s3bucket}/${dump_file_name} | awk '{print $3}')
        [ "${local_file_size}" = "${s3_file_size}" ] || { errorContinue "転送元ファイル（$local_file_size）と転送先ファイル（$s3_file_size）のサイズ不一致。"; }
        logInfo "転送元ファイル（$local_file_size）と転送先ファイル（$s3_file_size）のサイズ一致。"

        # ダンプファイル削除
        rm -f ${TMP_DIR}/${dump_file_name}
        logInfo "古い転送元ファイルを削除。"

        logInfo "=== DB Instance Identifier: ${mysqldb_identifier} , DB: ${mysqldb_db} 終了 ===\n"
}

# バックアップファイル名（YYYYMMDD）
BACKUP_FILE_NAME=$(getDate)

RESULT_MESSAGE=$(run $BACKUP_FILE_NAME 2>&1)

is_success=$(isSuccess)
if [ $is_success -ne 0 ]; then
    logError "### DB mysqldump のバックアップ異常終了。 ###"

    # Warning: Using a password on the command line interface can be insecure. を結果から除外する
    RESULT_MESSAGE=${RESULT_MESSAGE//Warning: Using a password on the command line interface can be insecure./}

    MAIL_BODY=$(getBackuplog)
    sendMail "$MAIL_BODY" "DB mysqldump バックアップ：異常終了（エラーあり）" "$RESULT_MESSAGE"

    exit $ERROR_CODE
else
    logInfo "### DB mysqldump のバックアップ正常終了。 ###"

    # Warning: Using a password on the command line interface can be insecure. を結果から除外する
    RESULT_MESSAGE=${RESULT_MESSAGE//Warning: Using a password on the command line interface can be insecure./}

    MAIL_BODY=$(getBackuplog)
    sendMail "$MAIL_BODY" "DB mysqldump バックアップ：正常終了" "$RESULT_MESSAGE"

    exit 0
fi
