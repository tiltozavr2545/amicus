// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get unexpectedError => 'Неожиданная ошибка. Попробуйте ещё раз.';

  @override
  String get cancelButton => 'Отмена';

  @override
  String get deleteButton => 'Удалить';

  @override
  String get saveButton => 'Сохранить';

  @override
  String get nameLabel => 'Имя';

  @override
  String get passwordLabel => 'Пароль';

  @override
  String get nameRequiredError => 'Введи имя';

  @override
  String get signUpTitle => 'Регистрация';

  @override
  String get signUpButton => 'Зарегистрироваться';

  @override
  String get goToSignInButton => 'Перейти ко входу';

  @override
  String get alreadyHaveAccountButton => 'Уже есть аккаунт? Войти';

  @override
  String get emailAlreadyRegisteredError =>
      'Этот email уже зарегистрирован. Попробуй войти.';

  @override
  String confirmationEmailSentMessage(String email) {
    return 'Письмо со ссылкой для подтверждения отправлено на $email. Перейди по ссылке в письме, потом вернись сюда и войди с этим email и паролем.';
  }

  @override
  String get signInTitle => 'Вход';

  @override
  String get signInButton => 'Войти';

  @override
  String get noAccountSignUpButton => 'Нет аккаунта? Зарегистрироваться';

  @override
  String get forgotPasswordButton => 'Забыли пароль?';

  @override
  String get resetPasswordTitle => 'Сброс пароля';

  @override
  String get resetPasswordInstructions =>
      'Введи email, привязанный к аккаунту, — пришлём ссылку для сброса пароля.';

  @override
  String resetPasswordSuccessMessage(String email) {
    return 'Если аккаунт с email $email существует, на него отправлено письмо со ссылкой для сброса пароля.';
  }

  @override
  String get sendLinkButton => 'Отправить ссылку';

  @override
  String get backToSignInButton => 'Вернуться ко входу';

  @override
  String get feedTabLabel => 'Лента';

  @override
  String get connectionsTitle => 'Знакомства';

  @override
  String get newPostTitle => 'Новый пост';

  @override
  String get profileTitle => 'Профиль';

  @override
  String get inviteSectionTitle => 'Пригласить';

  @override
  String get copyTooltip => 'Скопировать';

  @override
  String get codeCopiedMessage => 'Код скопирован';

  @override
  String get createInviteCodeButton => 'Создать код приглашения';

  @override
  String get createNewCodeButton => 'Создать новый код';

  @override
  String get haveCodeSectionTitle => 'У меня есть код';

  @override
  String get inviteCodeLabel => 'Код приглашения';

  @override
  String get inviteCodeRequiredError => 'Введи код приглашения';

  @override
  String get activateButton => 'Активировать';

  @override
  String get myConnectionsTitle => 'Мои знакомые';

  @override
  String get failedToLoadConnectionsError =>
      'Не удалось загрузить список. Попробуйте ещё раз.';

  @override
  String get noConnectionsYetMessage =>
      'Пока нет знакомых — активируй код или создай свой выше';

  @override
  String nowConnectedWithMessage(String name) {
    return 'Вы теперь знакомы с $name';
  }

  @override
  String get muteFriendTooltip => 'Заглушить';

  @override
  String get unmuteFriendTooltip => 'Включить обратно';

  @override
  String muteFriendTitle(String name) {
    return 'Заглушить $name?';
  }

  @override
  String get muteFriendContent =>
      'Их посты перестанут показываться в вашей ленте. Знакомство не разорвётся.';

  @override
  String get muteButton => 'Заглушить';

  @override
  String get blockFriendTooltip => 'Заблокировать';

  @override
  String blockFriendTitle(String name) {
    return 'Заблокировать $name?';
  }

  @override
  String get blockFriendContent =>
      'Ни вы, ни он не будете видеть посты друг друга. Знакомство не разорвётся.';

  @override
  String get blockButton => 'Заблокировать';

  @override
  String get unblockButton => 'Разблокировать';

  @override
  String get blockedUsersTooltip => 'Заблокированные';

  @override
  String get blockedUsersTitle => 'Заблокированные';

  @override
  String get noBlockedUsersMessage => 'Вы никого не заблокировали';

  @override
  String get publishButton => 'Опубликовать';

  @override
  String get whatsNewHint => 'Что нового?';

  @override
  String get addPhotoButton => 'Добавить фото';

  @override
  String get replacePhotoButton => 'Заменить фото';

  @override
  String get addTextOrPhotoError => 'Добавь текст или фото';

  @override
  String get failedToPublishError =>
      'Не удалось опубликовать. Попробуйте ещё раз.';

  @override
  String get deletePostTitle => 'Удалить пост?';

  @override
  String get deletePostContent =>
      'Пост, фото и комментарии к нему будут удалены.';

  @override
  String get failedToLoadFeedError =>
      'Не удалось загрузить ленту. Попробуйте ещё раз.';

  @override
  String get failedToDeletePostError =>
      'Не удалось удалить пост. Попробуйте ещё раз.';

  @override
  String get noPostsYetMessage =>
      'Пока нет постов от знакомых. Добавь знакомых или напиши первым.';

  @override
  String get addConnectionsButton => 'Добавить знакомых';

  @override
  String get likeTooltip => 'Нравится';

  @override
  String get neutralTooltip => 'Нейтрально';

  @override
  String get dislikeTooltip => 'Не нравится';

  @override
  String get signOutTooltip => 'Выйти';

  @override
  String get darkThemeToggleTooltip => 'Переключить тёмную тему';

  @override
  String get failedToLoadProfileError =>
      'Не удалось загрузить профиль. Попробуйте ещё раз.';

  @override
  String get commentsTitle => 'Комментарии';

  @override
  String get deleteCommentTitle => 'Удалить комментарий?';

  @override
  String get noCommentsYetMessage => 'Пока нет комментариев';

  @override
  String get writeCommentHint => 'Написать комментарий...';

  @override
  String get failedToLoadCommentsError =>
      'Не удалось загрузить комментарии. Попробуйте ещё раз.';

  @override
  String get failedToDeleteCommentError =>
      'Не удалось удалить комментарий. Попробуйте ещё раз.';

  @override
  String get failedToSendCommentError =>
      'Не удалось отправить. Попробуйте ещё раз.';

  @override
  String get connectionKnownLessThanDay => 'Знакомы меньше дня';

  @override
  String connectionKnownDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days дня',
      many: '$days дней',
      few: '$days дня',
      one: '$days день',
    );
    return 'Знакомы $_temp0';
  }

  @override
  String connectionKnownMonths(int months) {
    String _temp0 = intl.Intl.pluralLogic(
      months,
      locale: localeName,
      other: '$months месяца',
      many: '$months месяцев',
      few: '$months месяца',
      one: '$months месяц',
    );
    return 'Знакомы $_temp0';
  }

  @override
  String connectionKnownYears(int years) {
    String _temp0 = intl.Intl.pluralLogic(
      years,
      locale: localeName,
      other: '$years года',
      many: '$years лет',
      few: '$years года',
      one: '$years год',
    );
    return 'Знакомы $_temp0';
  }

  @override
  String connectionSummary(String duration, String date) {
    return '$duration — с $date';
  }
}
