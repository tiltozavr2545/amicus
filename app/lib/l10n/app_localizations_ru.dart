// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String unexpectedError(Object error) {
    return 'Неожиданная ошибка: $error';
  }

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
  String get activateButton => 'Активировать';

  @override
  String get myConnectionsTitle => 'Мои знакомые';

  @override
  String failedToLoadConnectionsError(Object error) {
    return 'Не удалось загрузить список: $error';
  }

  @override
  String get noConnectionsYetMessage =>
      'Пока нет знакомых — активируй код или создай свой выше';

  @override
  String nowConnectedWithMessage(String name) {
    return 'Вы теперь знакомы с $name';
  }

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
  String failedToPublishError(Object error) {
    return 'Не удалось опубликовать: $error';
  }

  @override
  String get deletePostTitle => 'Удалить пост?';

  @override
  String get deletePostContent =>
      'Пост, фото и комментарии к нему будут удалены.';

  @override
  String failedToLoadFeedError(Object error) {
    return 'Не удалось загрузить ленту: $error';
  }

  @override
  String failedToDeletePostError(Object error) {
    return 'Не удалось удалить пост: $error';
  }

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
  String failedToLoadProfileError(Object error) {
    return 'Ошибка загрузки профиля: $error';
  }

  @override
  String get commentsTitle => 'Комментарии';

  @override
  String get deleteCommentTitle => 'Удалить комментарий?';

  @override
  String get noCommentsYetMessage => 'Пока нет комментариев';

  @override
  String get writeCommentHint => 'Написать комментарий...';

  @override
  String failedToLoadCommentsError(Object error) {
    return 'Не удалось загрузить комментарии: $error';
  }

  @override
  String failedToDeleteCommentError(Object error) {
    return 'Не удалось удалить комментарий: $error';
  }

  @override
  String failedToSendCommentError(Object error) {
    return 'Не удалось отправить: $error';
  }

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
